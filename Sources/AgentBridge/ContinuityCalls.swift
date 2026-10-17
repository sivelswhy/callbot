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
import AppKit
import ApplicationServices
import CoreAudio
import AudioPipeline
import Shared

/// Calls handled on the Mac through macOS "Calls from iPhone" (Continuity): the call audio
/// plays on the Mac, and is wired to the agent through two virtual BlackHole devices.
///
///     FaceTime output → BlackHole 2ch  → agent capture (the agent hears the other party)
///     agent voice     → BlackHole 16ch → FaceTime microphone (the other party hears the agent)
public final class ContinuityCalls: @unchecked Sendable {
    public struct Devices: Sendable {
        /// Receives the call audio (FaceTime output), read by the agent
        public let fromCall: AudioDeviceInfo
        /// Carries the agent's voice (FaceTime input)
        public let toCall: AudioDeviceInfo
    }

    private let logger = CallbotLogger(category: .app)
    private let deviceManager = AudioDeviceManager()
    private let lock = NSLock()
    private var savedOutput: AudioDeviceID?
    private var savedInput: AudioDeviceID?

    /// UID of the multi-output device an earlier version created during calls
    static let legacyListeningOutputUID = "com.phonebt.call-listening-output"

    private let fromCallName: String
    private let toCallName: String

    public init(fromCallDevice: String = "BlackHole 2ch", toCallDevice: String = "BlackHole 16ch") {
        self.fromCallName = fromCallDevice
        self.toCallName = toCallDevice
    }

    // MARK: Devices

    public func findDevices() -> Devices? {
        let all = deviceManager.getAllDevices()
        guard let from = all.first(where: { $0.name.localizedCaseInsensitiveContains(fromCallName) && $0.hasInput }),
              let to = all.first(where: { $0.name.localizedCaseInsensitiveContains(toCallName) && $0.hasOutput }) else {
            return nil
        }
        return Devices(fromCall: from, toCall: to)
    }

    /// The user's own output before routing (for listening in)
    public var userOutputDevice: AudioDeviceID? {
        lock.lock(); defer { lock.unlock() }
        return savedOutput
    }

    /// The call audio is captured from what the Mac plays (macOS 14.2+), so FaceTime keeps
    /// playing the call on the user's speakers. Otherwise the output goes to BlackHole 2ch.
    public var capturesSystemAudio: Bool {
        if #available(macOS 14.2, *) { return systemCaptureUsable }
        return false
    }
    /// Set to false when the system capture fails, to fall back to BlackHole 2ch
    public var systemCaptureUsable = true

    /// Point FaceTime's microphone (system default input) at the agent's voice, and — without
    /// system capture — its output at BlackHole 2ch. Only for the duration of a call:
    /// `restoreSystemAudio` gives the Mac its devices back.
    /// (A multi-output device "BlackHole + speakers" doesn't work: FaceTime's call audio
    /// goes silent on it.)
    public func routeSystemAudio(to devices: Devices) {
        lock.lock()
        let alreadyRouted = savedOutput != nil
        if !alreadyRouted {
            // Never remember a virtual device as the user's own (left over by a crash)
            savedOutput = realDevice(deviceManager.getDefaultOutputDevice(), output: true)
            savedInput = realDevice(deviceManager.getDefaultInputDevice(), output: false)
        }
        lock.unlock()

        _ = deviceManager.setDefaultInputDevice(devices.toCall.id)
        if capturesSystemAudio {
            logger.info("System audio routed: input → \(devices.toCall.name), output unchanged (system capture)")
        } else {
            _ = deviceManager.setDefaultOutputDevice(devices.fromCall.id)
            logger.info("System audio routed: output → \(devices.fromCall.name), input → \(devices.toCall.name)")
        }
    }

    /// Remove the multi-output device an earlier version created during calls
    private func destroyLegacyListeningOutput() {
        for device in deviceManager.getAllDevices() where device.uid == Self.legacyListeningOutputUID {
            AudioHardwareDestroyAggregateDevice(device.id)
            logger.info("Leftover multi-output device removed")
        }
    }

    /// Give the Mac its speakers and microphone back
    public func restoreSystemAudio() {
        lock.lock()
        let (out, inp) = (savedOutput, savedInput)
        savedOutput = nil
        savedInput = nil
        lock.unlock()

        if let out { _ = deviceManager.setDefaultOutputDevice(out) }
        if let inp { _ = deviceManager.setDefaultInputDevice(inp) }
        if out != nil { logger.info("System audio restored") }
        releaseVirtualDefaults()
    }

    /// Outside a call the Mac must use its real devices: if the default output or input
    /// is still a BlackHole device (e.g. after a crash mid-call), switch to the built-in one.
    public func releaseVirtualDefaults() {
        let outID = deviceManager.getDefaultOutputDevice()
        if isVirtual(outID), let real = realDevice(outID, output: true) {
            _ = deviceManager.setDefaultOutputDevice(real)
            logger.info("Default output was a virtual device — switched back to a real one")
        }
        let inID = deviceManager.getDefaultInputDevice()
        if isVirtual(inID), let real = realDevice(inID, output: false) {
            _ = deviceManager.setDefaultInputDevice(real)
            logger.info("Default input was a virtual device — switched back to a real one")
        }
        destroyLegacyListeningOutput()
    }

    private func isVirtual(_ id: AudioDeviceID) -> Bool {
        guard let device = deviceManager.getAllDevices().first(where: { $0.id == id }) else { return false }
        return Self.isVirtual(device)
    }

    private static func isVirtual(_ device: AudioDeviceInfo) -> Bool {
        device.name.localizedCaseInsensitiveContains("BlackHole") || device.uid == legacyListeningOutputUID
    }

    /// `id` if it's a real device, otherwise the built-in (or first non-virtual) device
    private func realDevice(_ id: AudioDeviceID, output: Bool) -> AudioDeviceID? {
        if id != 0 && !isVirtual(id) { return id }
        let candidates = deviceManager.getAllDevices().filter {
            (output ? $0.hasOutput : $0.hasInput) && !Self.isVirtual($0)
        }
        return (candidates.first(where: { $0.transportType == kAudioDeviceTransportTypeBuiltIn }) ?? candidates.first)?.id
    }

    // MARK: Call control (FaceTime UI)

    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Show the system prompt to grant Accessibility (needed to click Call / Accept)
    public static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Remove Callbot's Accessibility entry, then ask again. An ad hoc signed rebuild keeps
    /// the old entry switched on in System Settings, but it no longer matches the app.
    public static func resetAccessibility() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.callbot.app"]
        try? process.run()
        process.waitUntilExit()
        requestAccessibility()
    }

    /// Place a call through the iPhone. Opens the tel: URL and confirms the call prompt.
    /// - Parameter started: true once the call is ringing, i.e. no confirmation is needed anymore
    @discardableResult
    public func dial(_ number: String, until started: @escaping @Sendable () -> Bool = { false }) async -> Bool {
        guard let url = URL(string: "tel:\(number)") else { return false }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
        logger.info("Continuity dial: opened \(url.absoluteString)")
        let confirmed = await clickButton(titles: ["Appeler", "Call", "Composer", "Dial"], timeout: 6, until: started)
        logger.info("Continuity dial: confirm button \(confirmed ? "clicked" : "not found")")
        return confirmed
    }

    /// Answer an incoming call on the Mac (clicks Accept on the call notification)
    @discardableResult
    public func answer() async -> Bool {
        let ok = await clickButton(titles: ["Accepter", "Accept", "Répondre", "Answer", "Décrocher"], timeout: 6)
        logger.info("Continuity answer: \(ok ? "clicked" : "button not found")")
        return ok
    }

    /// Hang up from the Mac UI (fallback when the Bluetooth control link is unavailable)
    @discardableResult
    public func hangUp() async -> Bool {
        await clickButton(titles: ["Raccrocher", "End", "Terminer", "Fin"], timeout: 2)
    }

    // MARK: Keypad (DTMF)

    /// Press keys on the keypad of the Mac's call window (Phone / FaceTime). During a
    /// Continuity call this is the channel that reaches the network: keys sent to the iPhone
    /// over Bluetooth (AT+VTS) were ignored.
    /// - Returns: false if the keypad couldn't be found (the caller then falls back to Bluetooth)
    public func pressKeypad(_ digits: [Character], interval: TimeInterval = 0.3) async -> Bool {
        guard Self.isAccessibilityTrusted, !digits.isEmpty else { return false }
        for (i, digit) in digits.enumerated() {
            if i > 0 { try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
            var pressed = await MainActor.run { Self.pressKeypadButton(digit) }
            if !pressed {
                // The keypad is hidden: open it (Keypad / Clavier button), then retry
                _ = await MainActor.run { Self.findAndPress(titles: ["Clavier", "Keypad", "Pavé numérique"], exact: true) }
                // The keypad takes a moment to appear
                for _ in 0..<10 where !pressed {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    pressed = await MainActor.run { Self.pressKeypadButton(digit) }
                }
            }
            guard pressed else {
                logger.error("Keypad button \(digit) not found")
                return false
            }
            logger.info("Keypad: pressed \(digit)")
        }
        return true
    }

    /// Labels a keypad button may have for a key ("2", "2 ABC", "étoile", "dièse"…)
    static func keypadLabels(_ digit: Character) -> [String] {
        switch digit {
        case "*": return ["*", "étoile", "star", "asterisk", "astérisque"]
        case "#": return ["#", "dièse", "pound", "hash", "carré"]
        default: return [String(digit)]
        }
    }

    @MainActor
    private static func pressKeypadButton(_ digit: Character) -> Bool {
        let labels = keypadLabels(digit)
        for app in callApps() {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            if let button = findButton(in: root, depth: 0, matching: { label in
                // "2" or "2 ABC", but not "20:41" or a phone number
                labels.contains { label == $0 || (label.hasPrefix($0 + " ") && label.count <= 8) }
            }) {
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    // MARK: - Accessibility automation

    /// Apps that show call UI: FaceTime window, notification banners, call service UI
    private static let callUIBundleIDs: Set<String> = [
        "com.apple.mobilephone",
        "com.apple.FaceTime",
        "com.apple.notificationcenterui",
        "com.apple.UserNotificationCenter",
        "com.apple.TelephonyUtilities",
        "com.apple.InCallService",
        "com.apple.CallHistory",
    ]

    private func clickButton(titles: [String], timeout: TimeInterval, until done: @Sendable () -> Bool = { false }) async -> Bool {
        guard Self.isAccessibilityTrusted else {
            logger.error("Accessibility not granted — can't click \(titles.first ?? "")")
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !done() {
            let clicked = await MainActor.run { Self.findAndPress(titles: titles) }
            if clicked { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    @MainActor
    private static func callApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return callUIBundleIDs.contains(id) || id.localizedCaseInsensitiveContains("facetime")
        }
    }

    @MainActor
    private static func findAndPress(titles: [String], exact: Bool = false) -> Bool {
        let wanted = titles.map { $0.lowercased() }
        for app in callApps() {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            if let button = findButton(in: root, depth: 0, matching: { label in
                wanted.contains { label == $0 || (!exact && label.hasPrefix($0)) }
            }) {
                let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
                if result == .success { return true }
            }
        }
        return false
    }

    private static func findButton(in element: AXUIElement, depth: Int, matching: (String) -> Bool) -> AXUIElement? {
        guard depth < 16 else { return nil }

        if attribute(element, kAXRoleAttribute) == kAXButtonRole as String {
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute]
                .compactMap { attribute(element, $0)?.lowercased().trimmingCharacters(in: .whitespaces) }
            if labels.contains(where: matching) {
                return element
            }
        }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else {
            return nil
        }
        for child in list {
            if let found = findButton(in: child, depth: depth + 1, matching: matching) { return found }
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
