// Copyright 2026 ICOA Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import AVFoundation
import Speech
import Shared

/// Captures audio from AVAudioEngine input and transcribes using Apple SFSpeechRecognizer
public final class AudioCapture: @unchecked Sendable {
    private let sessionManager: AudioSessionManager
    private let speechRecognizer: SFSpeechRecognizer
    private let logger = PhoneBTLogger(category: .audio)

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var restartTimer: Timer?
    private var lastTranscription: String = ""
    private var isCapturing = false
    private var handlerID: UUID?

    private let silenceTimeout: TimeInterval = 1.5
    private let maxRecognitionDuration: TimeInterval = 55 // restart before 60s limit

    /// Called with final transcribed text for each utterance
    public var onTranscription: ((String) -> Void)?

    public init(sessionManager: AudioSessionManager, locale: Locale = Locale(identifier: "fr-FR")) {
        self.sessionManager = sessionManager
        self.speechRecognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()!
    }

    /// Whether this locale can be transcribed fully offline on this Mac
    public static func supportsOnDevice(locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }

    /// Request speech recognition authorization. Must be called before start().
    public static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status == .authorized)
        }
    }

    /// Start capturing and transcribing audio from the engine's input node
    public func start() throws {
        guard !isCapturing else { return }
        isCapturing = true
        try startRecognition()
        logger.info("Audio capture started")
    }

    /// Stop capturing audio
    public func stop() {
        guard isCapturing else { return }
        isCapturing = false
        stopRecognition()
        logger.info("Audio capture stopped")
    }

    // MARK: - Private

    private func startRecognition() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        // Strictly on-device: audio never leaves the Mac
        request.requiresOnDeviceRecognition = true
        if !speechRecognizer.supportsOnDeviceRecognition {
            logger.error("On-device speech recognition unavailable for \(speechRecognizer.locale.identifier) — enable Dictation for this language in System Settings")
        }

        recognitionRequest = request
        lastTranscription = ""

        // Install tap on input node
        handlerID = sessionManager.addInputHandler { [weak self] buffer in
            self?.recognitionRequest?.append(buffer)
        }

        // Start recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty && text != self.lastTranscription {
                    self.lastTranscription = text
                    self.resetSilenceTimer()
                }

                if result.isFinal {
                    self.emitTranscription(text)
                }
            }

            if let error = error {
                // Recognition ended (could be timeout or error) — restart if still capturing
                self.logger.error("Recognition error: \(error.localizedDescription)")
                if self.isCapturing {
                    self.restartRecognitionAfterDelay()
                }
            }
        }

        // Schedule auto-restart before 60s limit
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.restartTimer = Timer.scheduledTimer(
                withTimeInterval: self.maxRecognitionDuration,
                repeats: false
            ) { [weak self] _ in
                guard let self = self, self.isCapturing else { return }
                self.logger.info("Auto-restarting recognition before 60s limit")
                self.emitPendingTranscription()
                self.restartRecognition()
            }
        }
    }

    private func stopRecognition() {
        DispatchQueue.main.async { [weak self] in
            self?.silenceTimer?.invalidate()
            self?.silenceTimer = nil
            self?.restartTimer?.invalidate()
            self?.restartTimer = nil
        }

        if let handlerID { sessionManager.removeInputHandler(handlerID) }
        handlerID = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    private func resetSilenceTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(
                withTimeInterval: self.silenceTimeout,
                repeats: false
            ) { [weak self] _ in
                self?.emitPendingTranscription()
            }
        }
    }

    private func emitPendingTranscription() {
        let text = lastTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        emitTranscription(text)
        lastTranscription = ""
    }

    private func emitTranscription(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logger.info("Transcription: \(trimmed)")
        onTranscription?(trimmed)
    }

    private func restartRecognitionAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.restartRecognition()
        }
    }

    private func restartRecognition() {
        stopRecognition()
        guard isCapturing else { return }
        do {
            try startRecognition()
            logger.info("Recognition restarted")
        } catch {
            logger.error("Failed to restart recognition: \(error)")
        }
    }
}
