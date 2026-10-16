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
import Shared

/// Captures what the Mac plays (all processes except PhoneBT) with a Core Audio process tap.
/// Used for Continuity calls: FaceTime plays the call on the user's speakers as usual (so the
/// user hears it, without the ducking FaceTime applies to other apps) and the agent hears it here.
/// Requires macOS 14.2 and the "system audio recording" permission (silence without it).
@available(macOS 14.2, *)
public final class SystemAudioTap: @unchecked Sendable {
    /// Mono float buffers delivered to `onBuffer`
    public let format: AVAudioFormat
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let logger = PhoneBTLogger(category: .audio)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let tapFormat: AudioStreamBasicDescription

    public init() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw SystemAudioTapError.failed("process tap", status) }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else {
            AudioHardwareDestroyProcessTap(tap)
            throw SystemAudioTapError.failed("tap format", status)
        }
        tapFormat = asbd
        format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: 1)!

        // The tap is read through a private aggregate device clocked by the default output
        let outputUID = Self.defaultOutputUID() ?? ""
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PhoneBT system capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw SystemAudioTapError.failed("aggregate device", status)
        }
        aggregateID = aggregateDevice
        logger.info("System audio tap ready (\(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch)")
    }

    deinit { stop() }

    public func start() throws {
        guard procID == nil else { return }
        let channels = Int(tapFormat.mChannelsPerFrame)
        let interleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let format = self.format

        var newProc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, nil) { [weak self] _, inData, _, _, _ in
            guard let self, let handler = self.onBuffer else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let first = list.first, first.mDataByteSize > 0 else { return }
            let frames = interleaved
                ? Int(first.mDataByteSize) / (4 * max(1, channels))
                : Int(first.mDataByteSize) / 4
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let out = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(frames)

            // Mix down to mono
            if interleaved {
                guard let src = first.mData?.assumingMemoryBound(to: Float.self) else { return }
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += src[i * channels + c] }
                    out[i] = sum / Float(channels)
                }
            } else {
                let sources = list.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
                guard !sources.isEmpty else { return }
                for i in 0..<frames {
                    var sum: Float = 0
                    for src in sources { sum += src[i] }
                    out[i] = sum / Float(sources.count)
                }
            }
            handler(buffer)
        }
        guard status == noErr, let newProc else { throw SystemAudioTapError.failed("IO proc", status) }
        procID = newProc
        status = AudioDeviceStart(aggregateID, newProc)
        guard status == noErr else { throw SystemAudioTapError.failed("start", status) }
        logger.info("System audio capture started")
    }

    public func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            logger.info("System audio capture stopped")
        }
    }

    // MARK: - Private

    /// PhoneBT's own audio (agent voice monitor) must not be captured
    private static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() -> String? {
        let manager = AudioDeviceManager()
        let id = manager.getDefaultOutputDevice()
        return manager.getAllDevices().first(where: { $0.id == id })?.uid
    }
}

public enum SystemAudioTapError: Error, LocalizedError {
    case failed(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .failed(let step, let status):
            return "System audio capture failed (\(step), OSStatus \(status))"
        }
    }
}
