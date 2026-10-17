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
import CoreAudio
import AudioToolbox
import Shared

/// Audio I/O for a call: an engine captures the call audio (input device) and a Core Audio
/// IO proc plays the agent's voice into the call (output device), so input and output can be
/// different devices (e.g. BlackHole 2ch in, BlackHole 16ch out for Continuity calls).
public final class AudioSessionManager: @unchecked Sendable {
    /// Capture engine (call audio from the other party)
    public let captureEngine: AVAudioEngine
    /// Voice sent to the call
    private var voiceOutput: VoiceOutput?
    /// Mono format of the voice buffers (the output device's sample rate)
    public private(set) var playbackFormat: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    private let logger = CallbotLogger(category: .audio)
    private let tapLock = NSLock()
    private var inputHandlers: [UUID: (AVAudioPCMBuffer) -> Void] = [:]
    private var tapInstalled = false
    private var captureEnabled = true
    private var useVoiceProcessing = false
    /// SystemAudioTap when the call audio is captured from what the Mac plays
    private var systemCapture: AnyObject?
    private var systemCaptureFormat: AVAudioFormat?
    private var running = false
    private var configObservers: [NSObjectProtocol] = []

    /// Format of the buffers delivered to input handlers
    public var inputFormat: AVAudioFormat {
        systemCaptureFormat ?? captureEngine.inputNode.outputFormat(forBus: 0)
    }

    /// True when the call audio comes from the system output (process tap) instead of a device
    public var capturesSystemAudio: Bool { systemCapture != nil }

    public init() {
        self.captureEngine = AVAudioEngine()
        // A device change (e.g. FaceTime opening BlackHole when the call starts) stops the engine
        configObservers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: captureEngine, queue: nil
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        })
    }

    deinit {
        configObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Configure input/output devices by UID
    /// - Parameter voiceProcessing: echo cancellation, useful only for acoustic paths (not virtual devices)
    public func configure(inputDeviceUID: String, outputDeviceUID: String, voiceProcessing: Bool = false) throws {
        try setDeviceUID(inputDeviceUID, on: captureEngine.inputNode.audioUnit!)
        try setVoiceOutput(uid: outputDeviceUID)
        useVoiceProcessing = voiceProcessing
        logger.info("Audio configured — input: \(inputDeviceUID), output: \(outputDeviceUID)")
    }

    /// Capture what the Mac plays (the call, played by FaceTime on the user's speakers) and
    /// send the agent's voice to `outputDeviceUID`
    @available(macOS 14.2, *)
    public func configureSystemCapture(outputDeviceUID: String) throws {
        let tap = try SystemAudioTap()
        tap.onBuffer = { [weak self] buffer in self?.deliver(buffer) }
        try setVoiceOutput(uid: outputDeviceUID)
        systemCapture = tap
        systemCaptureFormat = tap.format
        captureEnabled = false
        logger.info("Audio configured — input: system audio, output: \(outputDeviceUID)")
    }

    /// Configure a single full-duplex device (Bluetooth SCO)
    public func configure(deviceUID: String) throws {
        try configure(inputDeviceUID: deviceUID, outputDeviceUID: deviceUID, voiceProcessing: true)
    }

    /// Playback only on the system default output (voice test without a call)
    public func configureDefault() {
        captureEnabled = false
        setVoiceOutput(deviceID: AudioDeviceManager().getDefaultOutputDevice())
    }

    public func start() throws {
        if captureEnabled {
            if useVoiceProcessing, #available(macOS 14.0, *) {
                do {
                    try captureEngine.inputNode.setVoiceProcessingEnabled(true)
                    // Don't let voice processing duck other audio (the call monitor on the Mac speakers)
                    captureEngine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                    logger.info("Voice processing (AEC) enabled")
                } catch {
                    logger.error("Failed to enable voice processing: \(error)")
                }
            }
            // The capture engine needs a connected graph to run: feed a silent mixer
            captureEngine.mainMixerNode.outputVolume = 0
            captureEngine.connect(captureEngine.inputNode, to: captureEngine.mainMixerNode, format: inputFormat)
            try captureEngine.start()
        }
        if #available(macOS 14.2, *), let tap = systemCapture as? SystemAudioTap {
            try tap.start()
        }
        try voiceOutput?.start()
        tapLock.lock(); running = true; tapLock.unlock()
        logger.info("Audio engines started")
    }

    /// Play a voice buffer (mono, `playbackFormat`) into the call; returns once it has been played
    public func playVoice(_ buffer: AVAudioPCMBuffer) async {
        guard let output = voiceOutput, let data = buffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            output.enqueue(samples) { continuation.resume() }
        }
    }

    /// Stop the voice currently playing
    public func cancelVoice() {
        voiceOutput?.cancel()
    }

    /// For the debug log
    public var voiceStatusDescription: String {
        voiceOutput?.statusDescription ?? "no voice output"
    }

    private func restartAfterConfigurationChange() {
        tapLock.lock(); let isRunning = running; tapLock.unlock()
        guard isRunning, captureEnabled, !captureEngine.isRunning else { return }
        logger.info("Audio configuration changed — restarting capture engine")
        do { try captureEngine.start() } catch { logger.error("Capture engine restart failed: \(error)") }
    }

    /// Receive input (call) audio buffers. A single tap fans out to every handler,
    /// so speech recognition and the call monitor can both listen.
    @discardableResult
    public func addInputHandler(_ handler: @escaping (AVAudioPCMBuffer) -> Void) -> UUID {
        let id = UUID()
        tapLock.lock()
        inputHandlers[id] = handler
        let needsTap = !tapInstalled
        tapInstalled = true
        tapLock.unlock()

        if needsTap && systemCapture == nil {
            captureEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.deliver(buffer)
            }
        }
        return id
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        tapLock.lock()
        let handlers = Array(inputHandlers.values)
        tapLock.unlock()
        for h in handlers { h(buffer) }
    }

    public func removeInputHandler(_ id: UUID) {
        tapLock.lock()
        inputHandlers.removeValue(forKey: id)
        let removeTap = inputHandlers.isEmpty && tapInstalled
        if removeTap { tapInstalled = false }
        tapLock.unlock()
        if removeTap && systemCapture == nil { captureEngine.inputNode.removeTap(onBus: 0) }
    }

    public func stop() {
        tapLock.lock()
        running = false
        let hadTap = tapInstalled
        inputHandlers.removeAll()
        tapInstalled = false
        tapLock.unlock()
        if hadTap && systemCapture == nil { captureEngine.inputNode.removeTap(onBus: 0) }
        if #available(macOS 14.2, *), let tap = systemCapture as? SystemAudioTap {
            tap.stop()
        }
        voiceOutput?.stop()
        captureEngine.stop()
        logger.info("Audio engines stopped")
    }

    // MARK: - Private

    private func setVoiceOutput(uid: String) throws {
        guard let id = deviceID(forUID: uid) else { throw AudioSessionError.deviceNotFound(uid) }
        setVoiceOutput(deviceID: id)
    }

    private func setVoiceOutput(deviceID: AudioDeviceID) {
        let output = VoiceOutput(deviceID: deviceID)
        voiceOutput = output
        playbackFormat = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: 1)!
    }

    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        AudioDeviceManager().getAllDevices().first(where: { $0.uid == uid })?.id
    }

    private func setDeviceUID(_ uid: String, on audioUnit: AudioUnit) throws {
        // kAudioOutputUnitProperty_CurrentDevice takes an AudioDeviceID, not a UID
        guard var deviceID = deviceID(forUID: uid) else {
            throw AudioSessionError.deviceNotFound(uid)
        }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioSessionError.deviceConfigFailed(status)
        }
    }
}

public enum AudioSessionError: Error, LocalizedError {
    case deviceConfigFailed(OSStatus)
    case deviceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound(let uid):
            return "Audio device not found (\(uid))"
        case .deviceConfigFailed(let status):
            return "Failed to configure audio device (OSStatus \(status))"
        }
    }
}
