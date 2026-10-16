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
import NaturalLanguage
import Shared

/// Plays TTS audio synthesized on-device (AVSpeechSynthesizer) into the call
public final class TTSPlayer: @unchecked Sendable {
    private let sessionManager: AudioSessionManager
    private let voice: AVSpeechSynthesisVoice?
    private let defaultLanguage: String
    private let rate: Float
    private let logger = PhoneBTLogger(category: .audio)
    private let lock = NSLock()
    private var voicesByLanguage: [String: AVSpeechSynthesisVoice] = [:]
    private var activeUtterances = 0

    /// Called with true when playback starts and false when the last utterance ends
    /// (used to mute speech capture so we don't transcribe our own voice)
    public var onSpeakingChanged: ((Bool) -> Void)?

    /// Receives every buffer sent to the call (used to monitor the call on the Mac)
    public var onPlayback: ((AVAudioPCMBuffer) -> Void)?

    /// - Parameters:
    ///   - language: BCP-47 language used to pick a default voice (e.g. "fr-FR")
    ///   - voiceIdentifier: optional voice identifier or name (see `TTSPlayer.availableVoices`)
    ///   - rate: speech rate, 0.0–1.0 (AVSpeechUtteranceDefaultSpeechRate ≈ 0.5)
    public init(
        sessionManager: AudioSessionManager,
        language: String = "fr-FR",
        voiceIdentifier: String? = nil,
        rate: Float = AVSpeechUtteranceDefaultSpeechRate
    ) {
        self.sessionManager = sessionManager
        self.voice = Self.pickVoice(language: language, identifier: voiceIdentifier)
        self.defaultLanguage = String(language.prefix(2))
        self.rate = rate
        logger.info("TTS voice: \(voice?.name ?? "system default") (\(voice?.identifier ?? "-"))")
    }

    /// Voices installed on this Mac for a language, best quality first
    public static func availableVoices(language: String) -> [AVSpeechSynthesisVoice] {
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    public var voiceName: String { voice?.name ?? "défaut système" }

    /// Detect the language of a text (ISO 639-1), e.g. "en" for English
    public static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// Synthesize and play text through the audio engine's player node.
    /// - Parameter language: ISO code ("fr", "he", "en"…); detected from the text when nil
    public func speak(_ text: String, language: String? = nil) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let lang = language ?? Self.detectLanguage(trimmed) ?? defaultLanguage
        let buffer = try await synthesize(trimmed, voice: voiceFor(language: lang))

        setSpeaking(true)
        defer { setSpeaking(false) }

        onPlayback?(buffer)
        // Resume once played, or after the buffer's duration plus a margin if the device
        // stalls (otherwise speech capture would stay muted for the rest of the call)
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let session = sessionManager
        let logger = self.logger
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task {
                await session.playVoice(buffer)
                once.resume()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + duration + 3) {
                if once.resume() {
                    logger.error("TTS playback didn't complete in time (\(session.voiceStatusDescription))")
                }
            }
        }
    }

    /// Cancel any currently playing TTS audio
    public func cancelCurrentPlayback() {
        sessionManager.cancelVoice()
        logger.info("TTS playback cancelled")
    }

    // MARK: - Private

    private func voiceFor(language: String) -> AVSpeechSynthesisVoice? {
        let code = String(language.prefix(2)).lowercased()
        if code == defaultLanguage { return voice }
        lock.lock(); defer { lock.unlock() }
        if let cached = voicesByLanguage[code] { return cached }
        let found = Self.availableVoices(language: code).first
        if found == nil {
            logger.error("No TTS voice installed for '\(code)' — falling back to default voice")
        }
        let chosen = found ?? voice
        voicesByLanguage[code] = chosen
        return chosen
    }

    private func setSpeaking(_ starting: Bool) {
        lock.lock()
        let before = activeUtterances
        activeUtterances += starting ? 1 : -1
        let after = activeUtterances
        lock.unlock()
        if before == 0 && after == 1 { onSpeakingChanged?(true) }
        if before == 1 && after == 0 { onSpeakingChanged?(false) }
    }

    private static func pickVoice(language: String, identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, !identifier.isEmpty {
            if let v = AVSpeechSynthesisVoice(identifier: identifier) { return v }
            if let v = AVSpeechSynthesisVoice.speechVoices().first(where: {
                $0.name.localizedCaseInsensitiveCompare(identifier) == .orderedSame
            }) { return v }
        }
        // Prefer premium/enhanced voices, exact locale first
        let candidates = availableVoices(language: language)
        return candidates.first(where: { $0.language == language })
            ?? candidates.first
            ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Render the utterance offline into a mono buffer in the engine's playback format
    private func synthesize(_ text: String, voice: AVSpeechSynthesisVoice?) async throws -> AVAudioPCMBuffer {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate

        logger.info("TTS synth: \(text.prefix(50))...")

        // A fresh synthesizer per utterance avoids interleaving concurrent requests
        let synthesizer = AVSpeechSynthesizer()
        let (samples, sampleRate) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<([Float], Double), Error>) in
            var samples: [Float] = []
            var sampleRate: Double = 0
            var finished = false

            synthesizer.write(utterance) { buffer in
                guard !finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }

                if pcm.frameLength == 0 {
                    finished = true
                    if samples.isEmpty || sampleRate == 0 {
                        continuation.resume(throwing: TTSError.synthesisFailed)
                    } else {
                        continuation.resume(returning: (samples, sampleRate))
                    }
                    return
                }

                sampleRate = pcm.format.sampleRate
                Self.appendMonoSamples(from: pcm, to: &samples)
            }
        }
        withExtendedLifetime(synthesizer) {}

        return try convertToPlaybackFormat(samples: samples, sampleRate: sampleRate)
    }

    /// Copy the first channel of a buffer (Float32 or Int16) as Float samples
    private static func appendMonoSamples(from pcm: AVAudioPCMBuffer, to samples: inout [Float]) {
        let count = Int(pcm.frameLength)
        if let floats = pcm.floatChannelData {
            samples.append(contentsOf: UnsafeBufferPointer(start: floats[0], count: count))
        } else if let ints = pcm.int16ChannelData {
            let stride = pcm.format.isInterleaved ? Int(pcm.format.channelCount) : 1
            for i in 0..<count {
                samples.append(Float(ints[0][i * stride]) / Float(Int16.max))
            }
        }
    }

    private func convertToPlaybackFormat(samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
        guard let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw TTSError.bufferCreationFailed
        }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            source.floatChannelData![0].update(from: ptr.baseAddress!, count: samples.count)
        }

        let targetFormat = sessionManager.playbackFormat
        if targetFormat.sampleRate == sourceFormat.sampleRate && targetFormat.channelCount == 1 {
            return source
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw TTSError.converterCreationFailed
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw TTSError.bufferCreationFailed
        }

        var provided = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .endOfStream
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return source
        }

        if let error = error {
            throw TTSError.conversionFailed(error.localizedDescription)
        }
        return output
    }
}

/// Resumes a continuation only once (completion handler vs. timeout)
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    /// - Returns: true if this call resumed the continuation
    @discardableResult
    func resume() -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
        return c != nil
    }
}

public enum TTSError: Error, LocalizedError {
    case synthesisFailed
    case bufferCreationFailed
    case converterCreationFailed
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .synthesisFailed:
            return "Speech synthesis produced no audio"
        case .bufferCreationFailed:
            return "Failed to create audio buffer"
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        case .conversionFailed(let reason):
            return "Audio format conversion failed: \(reason)"
        }
    }
}
