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
import HFPCore
import AudioPipeline
import Shared

/// Call control that can be provided instead of raw HFP commands (e.g. Continuity calls)
public protocol CallActions: AnyObject, Sendable {
    func placeCall(_ number: String) throws
    func acceptCall() throws
    func endCall() throws
    /// Press keys in the call; return false to fall back to Bluetooth DTMF
    func sendKeys(_ digits: [Character]) async -> Bool
}

/// Executes tool calls by mapping them to HFP device commands
public final class ToolExecutor: @unchecked Sendable {
    private let device: HFPDevice
    private let audioRouter: AudioRouter
    private let logger = CallbotLogger(category: .agent)
    public var ttsPlayer: TTSPlayer?
    /// When set, dial/accept/end go through these actions instead of the HFP device
    public weak var actions: CallActions?
    /// Called when the agent needs information from the user (shown in the terminal)
    /// Question for the user, with optional clickable answers
    public var onAskUser: ((String, [String]) -> Void)?
    /// Delay between DTMF digits of a sequence
    public var dtmfInterval: TimeInterval = 0.35

    public init(device: HFPDevice, audioRouter: AudioRouter, ttsPlayer: TTSPlayer? = nil) {
        self.device = device
        self.audioRouter = audioRouter
        self.ttsPlayer = ttsPlayer
    }

    /// Execute a tool call and return JSON result string
    public func execute(toolName: String, input: [String: Any]) -> String {
        logger.info("Executing tool: \(toolName)")

        do {
            switch toolName {
            case "dial_number":
                return try executeDial(input: input)
            case "accept_call":
                return try executeAccept()
            case "end_call":
                return try executeEndCall()
            case "send_dtmf":
                return try executeSendDTMF(input: input)
            case "get_call_status":
                return executeGetCallStatus()
            case "get_phone_status":
                return executeGetPhoneStatus()
            case "say_to_caller":
                return executeSayToCaller(input: input)
            case "ask_user":
                return executeAskUser(input: input)
            default:
                return errorJSON("Unknown tool: \(toolName)")
            }
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    // MARK: - Tool Implementations

    private func executeDial(input: [String: Any]) throws -> String {
        guard let number = input["number"] as? String else {
            return errorJSON("Missing required parameter: number")
        }

        let sanitized = sanitizePhoneNumber(number)
        if let actions { try actions.placeCall(sanitized) } else { try device.dial(number: sanitized) }

        return successJSON([
            "status": "dialing",
            "number": sanitized,
        ])
    }

    private func executeAccept() throws -> String {
        if let actions { try actions.acceptCall() } else { try device.acceptCall() }

        return successJSON([
            "status": "answered",
        ])
    }

    private func executeEndCall() throws -> String {
        if let actions {
            try actions.endCall()
        } else {
            try device.endCall()
            audioRouter.restorePreviousRouting()
        }

        return successJSON([
            "status": "ended",
        ])
    }

    private func executeSendDTMF(input: [String: Any]) throws -> String {
        guard let raw = (input["digits"] ?? input["digit"]).map({ "\($0)" }) else {
            return errorJSON("Missing required parameter: digits")
        }
        let digits = Self.dtmfDigits(raw)
        guard !digits.isEmpty else {
            return errorJSON("Invalid DTMF digits: \(raw) (allowed: 0-9, *, #)")
        }

        if let actions {
            let device = self.device
            let interval = dtmfInterval
            Task.detached { [logger] in
                guard await !actions.sendKeys(digits) else { return }
                logger.info("Keypad unavailable — sending DTMF over Bluetooth")
                for (i, d) in digits.enumerated() {
                    if i > 0 { try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                    do { try device.sendDTMF(String(d)) } catch { logger.error("DTMF \(d) failed: \(error)") }
                }
            }
            return successJSON(["status": "sent", "digits": String(digits)])
        }

        // Send the first digit now (surfaces errors), the rest spaced out in the background
        try device.sendDTMF(String(digits[0]))
        if digits.count > 1 {
            let device = self.device
            let interval = dtmfInterval
            let rest = digits.dropFirst()
            Task.detached { [logger] in
                for d in rest {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    do { try device.sendDTMF(String(d)) } catch { logger.error("DTMF \(d) failed: \(error)") }
                }
            }
        }

        return successJSON([
            "status": "sent",
            "digits": String(digits),
        ])
    }

    /// Keep only valid DTMF characters
    public static func dtmfDigits(_ raw: String) -> [Character] {
        raw.filter { $0.isASCII && ($0.isNumber || $0 == "*" || $0 == "#") }.map { $0 }
    }

    private func executeAskUser(input: [String: Any]) -> String {
        guard let question = input["question"] as? String, !question.isEmpty else {
            return errorJSON("Missing required parameter: question")
        }
        let options = (input["options"] as? [Any] ?? []).map { "\($0)" }.filter { !$0.isEmpty }
        onAskUser?(question, options)
        return successJSON([
            "status": "asked",
            "note": "The user will answer in a later message. Meanwhile, ask the caller to hold on if needed.",
        ])
    }

    /// A call is ringing, being dialed or in progress
    public var isInCall: Bool { device.currentState.call != .idle }

    private func executeGetCallStatus() -> String {
        let state = device.currentState

        var result: [String: Any] = [
            "call_state": state.call.rawValue,
            "audio_connected": state.audio == .connected,
        ]

        if let call = state.activeCall {
            result["direction"] = call.direction.rawValue
            result["number"] = call.number ?? "unknown"
            if let duration = call.durationDescription {
                result["duration"] = duration
            }
        }

        return successJSON(result)
    }

    private func executeGetPhoneStatus() -> String {
        let phone = device.currentState.phoneStatus

        return successJSON([
            "signal_strength": phone.signalStrength,
            "battery_level": phone.batteryLevel,
            "service_available": phone.serviceAvailable,
            "operator": phone.operatorName ?? "unknown",
            "roaming": phone.roaming,
        ] as [String: Any])
    }

    private func executeSayToCaller(input: [String: Any]) -> String {
        guard let text = input["text"] as? String else {
            return errorJSON("Missing required parameter: text")
        }

        let language = input["language"] as? String

        guard let ttsPlayer = ttsPlayer else {
            return errorJSON("TTS not available — audio pipeline not started (no active call audio)")
        }

        // Fire TTS in a detached task so the tool returns immediately
        Task.detached { [logger] in
            do {
                try await ttsPlayer.speak(text, language: language)
                logger.info("TTS playback completed for: \(text.prefix(50))")
            } catch {
                logger.error("TTS playback failed: \(error)")
            }
        }

        return successJSON([
            "status": "speaking",
            "text": text,
        ])
    }

    // MARK: - Helpers

    private func sanitizePhoneNumber(_ number: String) -> String {
        // Keep digits, +, *, #
        return number.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
    }

    private func successJSON(_ data: [String: Any]) -> String {
        var result = data
        result["success"] = true
        return jsonString(result)
    }

    private func errorJSON(_ message: String) -> String {
        return jsonString(["success": false, "error": message])
    }

    private func jsonString(_ dict: [String: Any]) -> String {
        // Manual JSON serialization to avoid Foundation's unordered output
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"success\":false,\"error\":\"JSON serialization failed\"}"
        }
        return str
    }
}