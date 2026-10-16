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
import CoreAudio
import Shared

/// Writes the agent's voice straight to an output device with a Core Audio IO proc.
/// AVAudioEngine stalls when FaceTime reconfigures BlackHole at the start of a call (the
/// voice was queued but never played); a raw IO proc keeps running through those changes.
public final class VoiceOutput: @unchecked Sendable {
    /// Sample rate of the device: buffers given to `enqueue` must use it
    public let sampleRate: Double

    private struct Pending {
        let samples: [Float]
        var position: Int
        let completion: () -> Void
    }

    private let deviceID: AudioDeviceID
    private let deviceName: String
    private let logger = PhoneBTLogger(category: .audio)
    private let lock = NSLock()
    private var queue: [Pending] = []
    private var procID: AudioDeviceIOProcID?
    private var renderCount = 0

    public init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
        self.deviceName = AudioDeviceManager().getAllDevices().first(where: { $0.id == deviceID })?.name ?? "\(deviceID)"
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        self.sampleRate = rate > 0 ? rate : 48000
    }

    deinit { stop() }

    public func start() throws {
        guard procID == nil else { return }
        var newProc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&newProc, deviceID, nil) { [weak self] _, _, _, outData, _ in
            self?.render(outData)
        }
        guard status == noErr, let newProc else { throw VoiceOutputError.failed("IO proc", status) }
        procID = newProc
        status = AudioDeviceStart(deviceID, newProc)
        guard status == noErr else { throw VoiceOutputError.failed("start", status) }
        logger.info("Voice output started on \(deviceName) (\(sampleRate) Hz)")
    }

    public func stop() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
            logger.info("Voice output stopped")
        }
        cancel()
    }

    /// Queue mono samples at `sampleRate`; `completion` runs once they have been played
    public func enqueue(_ samples: [Float], completion: @escaping () -> Void) {
        guard !samples.isEmpty else { completion(); return }
        lock.lock()
        queue.append(Pending(samples: samples, position: 0, completion: completion))
        lock.unlock()
    }

    /// Drop everything queued (completions still run)
    public func cancel() {
        lock.lock()
        let dropped = queue
        queue.removeAll()
        lock.unlock()
        dropped.forEach { $0.completion() }
    }

    /// For the debug log: is the device asking for audio?
    public var statusDescription: String {
        lock.lock(); defer { lock.unlock() }
        return "voice output renders=\(renderCount) queued=\(queue.count)"
    }

    // MARK: - Private

    /// Real-time thread: fill the device buffers, the voice on the first two channels
    private func render(_ outData: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(outData)
        for buffer in buffers where buffer.mData != nil {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
        guard let first = buffers.first else { return }
        let interleavedChannels = Int(max(1, first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / (4 * interleavedChannels)

        var finished: [() -> Void] = []
        lock.lock()
        renderCount += 1
        var frame = 0
        while frame < frames, !queue.isEmpty {
            let available = queue[0].samples.count - queue[0].position
            let count = min(available, frames - frame)
            queue[0].samples.withUnsafeBufferPointer { src in
                for i in 0..<count {
                    write(src[queue[0].position + i], frame: frame + i, to: buffers)
                }
            }
            queue[0].position += count
            frame += count
            if queue[0].position >= queue[0].samples.count {
                finished.append(queue.removeFirst().completion)
            }
        }
        lock.unlock()
        if !finished.isEmpty {
            DispatchQueue.global().async { finished.forEach { $0() } }
        }
    }

    private func write(_ sample: Float, frame: Int, to buffers: UnsafeMutableAudioBufferListPointer) {
        if buffers.count == 1 {
            // One interleaved stream (e.g. BlackHole 16ch): channels 1 and 2
            let channels = Int(max(1, buffers[0].mNumberChannels))
            guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            for c in 0..<min(2, channels) { data[frame * channels + c] = sample }
        } else {
            // One buffer per channel: the first two
            for buffer in buffers.prefix(2) {
                let channels = Int(max(1, buffer.mNumberChannels))
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame * channels] = sample
            }
        }
    }
}

public enum VoiceOutputError: Error, LocalizedError {
    case failed(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .failed(let step, let status):
            return "Voice output failed (\(step), OSStatus \(status))"
        }
    }
}
