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

/// Plays the call on the Mac's speakers/headphones so the user can listen in:
/// the other party (from the SCO input) and the agent's voice (TTS sent to the call).
public final class CallMonitor: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let callerNode = AVAudioPlayerNode()
    private let voiceNode = AVAudioPlayerNode()
    private let submix = AVAudioMixerNode()
    /// Peak limiter with pre-gain: makes up for the ducking FaceTime applies to other apps
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
    ))
    private let outputDeviceID: AudioDeviceID?
    private var configObserver: NSObjectProtocol?
    private let callerFormat: AVAudioFormat
    private let voiceFormat: AVAudioFormat
    private let logger = PhoneBTLogger(category: .audio)
    private let lock = NSLock()
    private var running = false
    private var enabled = true
    private var level: Float = 0.8

    /// - Parameters:
    ///   - callerFormat: format of the call input buffers
    ///   - voiceFormat: format of the TTS buffers
    ///   - outputDeviceID: where to play (the user's speakers/headphones); nil = system default
    ///   - boostDecibels: gain added before a limiter. During a FaceTime call macOS ducks every
    ///     other app by about 20 dB, which makes the monitor inaudible without it.
    public init(callerFormat: AVAudioFormat, voiceFormat: AVAudioFormat, outputDeviceID: AudioDeviceID? = nil, boostDecibels: Float = 0) throws {
        self.callerFormat = callerFormat
        self.voiceFormat = voiceFormat
        self.outputDeviceID = outputDeviceID

        // Pick the output device before connecting nodes, so the graph uses its format
        applyOutputDevice()

        // caller/voice → submix → limiter (boost) → main mixer (listening volume) → output
        engine.attach(callerNode)
        engine.attach(voiceNode)
        engine.attach(submix)
        engine.attach(limiter)
        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        let busFormat = AVAudioFormat(
            standardFormatWithSampleRate: outFormat.sampleRate > 0 ? outFormat.sampleRate : 48000,
            channels: max(1, min(2, outFormat.channelCount))
        )!
        engine.connect(callerNode, to: submix, format: callerFormat)
        engine.connect(voiceNode, to: submix, format: voiceFormat)
        engine.connect(submix, to: limiter, format: busFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: busFormat)

        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, boostDecibels, 0)
        if boostDecibels > 0 { logger.info("Monitor boost: +\(boostDecibels) dB (limited)") }

        // A device change (e.g. the call starting) stops the engine: restart it
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// kAudioOutputUnitProperty_CurrentDevice takes an AudioDeviceID, not a UID
    private func applyOutputDevice() {
        guard var deviceID = outputDeviceID else {
            logger.info("Monitor output: system default device")
            return
        }
        let status = AudioUnitSetProperty(
            engine.outputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        let name = AudioDeviceManager().getAllDevices().first(where: { $0.id == deviceID })?.name ?? "\(deviceID)"
        logger.info("Monitor output: \(name) (status \(status))")
    }

    private func restartAfterConfigurationChange() {
        lock.lock(); let wasRunning = running; lock.unlock()
        guard wasRunning else { return }
        logger.info("Monitor: audio configuration changed — restarting")
        applyOutputDevice()
        do {
            try engine.start()
            callerNode.play()
            voiceNode.play()
        } catch {
            logger.error("Monitor restart failed: \(error)")
        }
    }

    /// For the debug log: is the monitor really playing?
    public var statusDescription: String {
        "monitor running=\(engine.isRunning) volume=\(engine.mainMixerNode.outputVolume)"
    }

    /// The user's listening device: current default output unless it's one of the call's
    /// devices, in which case the built-in speakers
    public static func listeningDevice(avoidingUIDs avoid: Set<String>) -> AudioDeviceID? {
        let manager = AudioDeviceManager()
        let devices = manager.getAllDevices()
        let defaultID = manager.getDefaultOutputDevice()
        if let current = devices.first(where: { $0.id == defaultID }), !avoid.contains(current.uid) {
            return current.id
        }
        return devices.first(where: { $0.hasOutput && $0.transportType == kAudioDeviceTransportTypeBuiltIn })?.id
    }

    public func start() throws {
        try engine.start()
        callerNode.play()
        voiceNode.play()
        lock.lock(); running = true; lock.unlock()
        applyVolume()
        logger.info("Call monitor started")
    }

    public func stop() {
        lock.lock(); running = false; lock.unlock()
        callerNode.stop()
        voiceNode.stop()
        engine.stop()
        logger.info("Call monitor stopped")
    }

    /// Listening on/off and volume (0…1), can be changed during the call
    public func configure(enabled: Bool, volume: Float) {
        lock.lock()
        self.enabled = enabled
        self.level = max(0, min(1, volume))
        lock.unlock()
        applyVolume()
    }

    /// Other party's audio (buffer from the SCO input tap)
    public func playCaller(_ buffer: AVAudioPCMBuffer) {
        schedule(buffer, on: callerNode, format: callerFormat)
    }

    /// Agent / user voice sent to the call
    public func playVoice(_ buffer: AVAudioPCMBuffer) {
        schedule(buffer, on: voiceNode, format: voiceFormat)
    }

    // MARK: - Private

    private func applyVolume() {
        lock.lock()
        let volume = enabled ? level : 0
        lock.unlock()
        engine.mainMixerNode.outputVolume = volume
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode, format: AVAudioFormat) {
        lock.lock()
        let active = running && enabled
        lock.unlock()
        guard active, buffer.format == format, let copy = Self.copy(buffer) else { return }
        node.scheduleBuffer(copy, completionHandler: nil)
    }

    /// Tap buffers are reused by the engine: copy before scheduling
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let dst = out.floatChannelData {
            let perChannel = buffer.format.isInterleaved ? frames * channels : frames
            for c in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                dst[c].update(from: src[c], count: perChannel)
            }
        } else if let src = buffer.int16ChannelData, let dst = out.int16ChannelData {
            let perChannel = buffer.format.isInterleaved ? frames * channels : frames
            for c in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                dst[c].update(from: src[c], count: perChannel)
            }
        } else {
            return nil
        }
        return out
    }
}
