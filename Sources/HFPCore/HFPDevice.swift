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
import IOBluetooth
import Shared

/// High-level wrapper around IOBluetoothHandsFreeDevice
public final class HFPDevice: @unchecked Sendable {
    private let device: IOBluetoothHandsFreeDevice
    private let hfpDelegate: HFPDelegate
    public let eventStream: HFPEventStream
    public let stateMachine: HFPStateMachine
    private let logger = CallbotLogger(category: .hfp)
    private var eventTask: Task<Void, Never>?

    public var deviceName: String {
        return device.device.name ?? "Unknown"
    }

    public var deviceAddress: String {
        return device.device.addressString ?? "??:??:??:??:??:??"
    }

    public var currentState: HFPState {
        return stateMachine.currentState
    }

    public init?(bluetoothDevice: IOBluetoothDevice) {
        let events = HFPEventStream()
        let delegate = HFPDelegate(eventStream: events)
        let sm = HFPStateMachine()

        self.eventStream = events
        self.hfpDelegate = delegate
        self.stateMachine = sm

        // Create HFP device with delegate. IOBluetooth delivers delegate callbacks on the
        // run loop of the thread that creates the object, so it must be the main thread.
        guard let hfDevice = Self.onMain({
            IOBluetoothHandsFreeDevice(device: bluetoothDevice, delegate: delegate)
        }) else {
            return nil
        }
        self.device = hfDevice

        Self.onMain {
            // Advertise narrowband (CVSD) only unless asked otherwise: wideband codec
            // negotiation (mSBC) is a common cause of SCO audio failing to open.
            let codecNegotiation = UInt32(1 << 7)
            if ProcessInfo.processInfo.environment["CALLBOT_WIDEBAND"] != "1" {
                hfDevice.supportedFeatures &= ~codecNegotiation
            }
            logger.info("HF features (Mac): 0x\(String(hfDevice.supportedFeatures, radix: 16))")
        }

        // Start event processing loop
        self.eventTask = Task { [weak self] in
            let stream = events.makeStream()
            for await event in stream {
                guard let self else { break }
                let before = self.stateMachine.currentState.call
                self.stateMachine.handleEvent(event)
                let after = self.stateMachine.currentState.call
                // Surface implicit call ends (busy, rejected…) as an explicit event
                if before != .idle && after == .idle {
                    if case .callEnded = event {} else {
                        events.emit(.callEnded)
                    }
                }
            }
        }
    }

    deinit {
        eventTask?.cancel()
    }

    // MARK: - Connection

    public func connect(timeout: TimeInterval = 45) async throws {
        logger.info("Connecting to \(deviceName)...")

        // Subscribe before connecting so a fast callback can't be missed
        let stream = eventStream.makeStream()

        // Already connected (e.g. a previous attempt finished after its timeout)
        if Self.onMain({ device.isConnected }) {
            eventStream.emit(.connected)
            return
        }

        // connect() initiates SLC (Service Level Connection) automatically.
        // Pairing confirmation on the phone/Mac may happen during this wait.
        Self.onMain { device.connect() }

        let hfDevice = device
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in stream {
                    switch event {
                    case .connected:
                        self.logger.info("Connected to \(self.deviceName)")
                        return
                    case .disconnected(let error):
                        throw BluetoothError.connectionFailed(
                            error?.localizedDescription ?? L("Connection refused by the phone", "Connexion refusée par le téléphone")
                        )
                    case .connectFailed(let error):
                        throw BluetoothError.connectionFailed(
                            error?.localizedDescription ?? L("Connection failed", "Connexion échouée")
                        )
                    default:
                        continue
                    }
                }
            }

            group.addTask {
                // Fallback: poll the connection state in case the delegate callback never comes
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    if Self.onMain({ hfDevice.isConnected }) {
                        self.logger.info("Connected to \(self.deviceName) (detected by polling)")
                        self.eventStream.emit(.connected)
                        return
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BluetoothError.connectionFailed(
                    L("No answer from the phone after \(Int(timeout)) s. On the iPhone, check that Bluetooth is on and the Mac is allowed (Settings › Bluetooth › this Mac), then try again.", "Pas de réponse du téléphone après \(Int(timeout)) s. Sur l'iPhone, vérifie que le Bluetooth est actif et que le Mac est autorisé (Réglages › Bluetooth › ce Mac), puis réessaie.")
                )
            }

            do {
                try await group.next()
            } catch {
                group.cancelAll()
                Self.onMain { hfDevice.disconnect() }
                throw error
            }
            group.cancelAll()
        }
    }

    /// Run IOBluetooth calls on the main thread (required for its callbacks to be delivered)
    static func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }

    public func disconnect() {
        logger.info("Disconnecting from \(deviceName)")
        Self.onMain { device.disconnect() }
    }

    // MARK: - Call Management

    public func dial(number: String) throws {
        guard currentState.connection == .connected else {
            throw BluetoothError.notConnected
        }
        logger.info("Dialing \(number)")
        eventStream.emit(.callDialing(number: number))
        Self.onMain { device.dialNumber(number) }
    }

    public func acceptCall() throws {
        guard currentState.connection == .connected else {
            throw BluetoothError.notConnected
        }
        logger.info("Accepting call")
        Self.onMain { device.acceptCall() }
    }

    public func endCall() throws {
        guard currentState.connection == .connected else {
            throw BluetoothError.notConnected
        }
        logger.info("Ending call")
        Self.onMain { device.endCall() }

        // If the phone doesn't confirm (e.g. the call had already failed), reset locally
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.currentState.call != .idle else { return }
            self.logger.info("No end-of-call confirmation from phone — resetting call state")
            self.eventStream.emit(.callEnded)
        }
    }

    public func sendDTMF(_ digit: String) throws {
        guard currentState.connection == .connected else {
            throw BluetoothError.notConnected
        }
        guard digit.count == 1 else {
            throw BluetoothError.commandFailed("DTMF must be a single character")
        }
        logger.info("Sending DTMF: \(digit)")
        Self.onMain { device.sendDTMF(digit) }
    }

    // MARK: - Audio

    public func connectAudio() throws {
        guard currentState.connection == .connected else {
            throw BluetoothError.notConnected
        }
        logger.info("Connecting SCO audio")
        Self.onMain { device.connectSCO() }
    }

    /// Features advertised by the phone (AG), available once connected
    public var phoneFeatures: UInt32 {
        Self.onMain { device.deviceSupportedFeatures }
    }

    public var isAudioConnected: Bool {
        Self.onMain { device.isSCOConnected() }
    }

    public func disconnectAudio() {
        logger.info("Disconnecting SCO audio")
        Self.onMain { device.disconnectSCO() }
    }

    public func transferAudioToComputer() throws {
        guard currentState.connection == .connected else {
            throw BluetoothError.notConnected
        }
        logger.info("Transferring audio to computer")
        Self.onMain { device.transferAudioToComputer() }
    }

    // MARK: - AT Commands

    /// Send a raw AT command
    public func sendATCommand(_ command: String) throws {
        guard currentState.connection == .connected else {
            throw BluetoothError.notConnected
        }
        logger.debug("Sending AT command: \(command)")
        Self.onMain { device.send(atCommand: command) }
    }

    /// Request current call list (CLCC)
    public func requestCallList() throws {
        try sendATCommand("+CLCC")
    }

    /// Request operator name (COPS)
    public func requestOperator() throws {
        try sendATCommand("+COPS?")
    }
}