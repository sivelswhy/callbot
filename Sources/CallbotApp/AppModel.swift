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
import SwiftUI
import AppKit
import UserNotifications
import HFPCore
import AgentBridge
import Shared

/// UI state for the Mac app, bridging PhoneSession callbacks to the main thread
@MainActor
final class AppModel: ObservableObject {
    enum InputMode: String, CaseIterable, Identifiable {
        case agent
        case say
        var id: String { rawValue }

        var label: String {
            switch self {
            case .agent: return L("Instruction to the agent", "Instruction à l'agent")
            case .say: return L("Say in the call", "Dire dans l'appel")
            }
        }
    }

    let session = PhoneSession()

    @Published var devices: [DiscoveredDevice] = []
    @Published var selectedAddress: String?
    @Published var state: HFPState?
    @Published var isConnecting = false
    @Published var connectedName: String?

    @Published var agentEnabled = false
    @Published var autoAnswer = true
    @Published var agentStarting = false
    @Published var agentThinking = false

    @Published var log: [SessionLogEntry] = []
    @Published var pendingQuestion: String?
    /// Question shown in the pop-up (cleared when answered or dismissed)
    @Published var questionPopup: String?
    @Published var questionOptions: [String] = []
    @Published var questionAnswer = ""

    @Published var inputText = ""
    @Published var inputMode: InputMode = .agent
    @Published var dialNumber = ""

    @Published var monitorEnabled = true {
        didSet { session.setMonitor(enabled: monitorEnabled, volume: Float(monitorVolume)) }
    }
    @Published var monitorVolume = 0.8 {
        didSet { session.setMonitor(enabled: monitorEnabled, volume: Float(monitorVolume)) }
    }

    /// Language spoken by the other party ("auto" = Whisper detects it)
    @Published var callLanguage = "auto" {
        didSet { session.setCallLanguage(callLanguage == "auto" ? nil : callLanguage) }
    }

    /// Language of the app
    @Published var uiLanguage = UILanguage.current {
        didSet {
            UILanguage.current = uiLanguage
            UserDefaults.standard.set(uiLanguage.rawValue, forKey: "uiLanguage")
            Task { await runChecks() }
        }
    }
    /// Language the agent uses with the user (reports, questions, translations of the call)
    @Published var agentLanguage = UILanguage.agent {
        didSet {
            UILanguage.agent = agentLanguage
            UserDefaults.standard.set(agentLanguage.rawValue, forKey: "agentLanguage")
            restartAgentIfRunning()
        }
    }

    @Published var profileText = ""
    @Published var showProfile = false
    @Published var checks: [PhoneSession.CheckResult] = [] {
        // Show the details as soon as something needs fixing
        didSet { if checks.contains(where: { !$0.ok }) { showChecks = true } }
    }
    @Published var showChecks = false

    init() {
        BluetoothManager.requestAuthorization()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // Ask macOS once: afterwards the Accessibility check shows the state and the fix,
        // instead of a system pop-up at every launch
        if session.config.audioMode == .continuity && !ContinuityCalls.isAccessibilityTrusted
            && !UserDefaults.standard.bool(forKey: "accessibilityPrompted") {
            UserDefaults.standard.set(true, forKey: "accessibilityPrompted")
            ContinuityCalls.requestAccessibility()
        }
        profileText = session.loadProfile()
        session.onLog = { [weak self] entry in
            Task { @MainActor in self?.append(entry) }
        }
        session.onStateChange = { [weak self] state in
            Task { @MainActor in self?.state = state }
        }
        refreshDevices()
        Task {
            await session.requestAudioPermissions()
            await runChecks()
        }
        // Back from System Settings (e.g. after granting Accessibility): refresh the checks
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.runChecks() }
        }
        // System Settings doesn't activate Callbot when the switch is toggled: watch the
        // Accessibility state so the marker turns green as soon as it's granted
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAccessibilityCheck() }
        }
    }

    private func refreshAccessibilityCheck() {
        let label = L("Accessibility", "Accessibilité")
        guard let index = checks.firstIndex(where: { $0.label == label }),
              checks[index].ok != ContinuityCalls.isAccessibilityTrusted else { return }
        Task { await runChecks() }
    }

    // MARK: Derived state

    var isConnected: Bool { state?.connection == .connected }
    var callStatus: CallStatus { state?.call ?? .idle }
    var inCall: Bool { callStatus != .idle && callStatus != .ended }
    var audioConnected: Bool { state?.audio == .connected }

    // MARK: Actions

    func refreshDevices() {
        devices = session.pairedPhones()
        if selectedAddress == nil || !devices.contains(where: { $0.address == selectedAddress }) {
            selectedAddress = devices.first(where: { $0.isHandsFreeGateway })?.address ?? devices.first?.address
        }
    }

    func toggleConnection() {
        if isConnected {
            agentEnabled = false
            session.disconnect()
            connectedName = nil
            return
        }
        guard let device = devices.first(where: { $0.address == selectedAddress }) else { return }
        isConnecting = true
        Task {
            do {
                try await session.connect(to: device)
                connectedName = device.name
                state = session.state
            } catch {
                append(SessionLogEntry(kind: .error, text: L("Connection failed: ", "Connexion échouée : ") + error.localizedDescription))
            }
            isConnecting = false
        }
    }

    func setAgent(enabled: Bool) {
        if !enabled {
            session.stopAgent()
            return
        }
        agentStarting = true
        Task {
            do {
                try await session.startAgent(autoAnswer: autoAnswer)
            } catch {
                append(SessionLogEntry(kind: .error, text: error.localizedDescription))
                agentEnabled = false
            }
            agentStarting = false
        }
    }

    /// Restart the agent so a changed option or profile is taken into account
    func restartAgentIfRunning() {
        guard agentEnabled, !agentStarting else { return }
        setAgent(enabled: true)
    }

    /// Answer from the question pop-up: a clicked option is sent as the user's choice
    func chooseOption(_ option: String) {
        answerQuestion(L("I choose: ", "Je choisis : ") + option)
    }

    /// Answer from the question pop-up
    func answerQuestion(_ answer: String) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        questionPopup = nil
        questionAnswer = ""
        guard !text.isEmpty else { return }
        pendingQuestion = nil
        agentThinking = true
        Task {
            await session.sendToAgent(text)
            agentThinking = false
        }
    }

    /// The agent is blocked on the user: sound, bring the window forward, system notification
    private func alertUser(question: String) {
        NSSound(named: "Glass")?.play()
        NSApp.requestUserAttention(.criticalRequest)
        NSApp.activate(ignoringOtherApps: true)
        let content = UNMutableNotificationContent()
        content.title = L("The agent needs you", "L'agent a besoin de toi")
        content.body = question
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    func submitInput() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        switch inputMode {
        case .say:
            session.say(text)
        case .agent:
            pendingQuestion = nil
            agentThinking = true
            Task {
                await session.sendToAgent(text)
                agentThinking = false
            }
        }
    }

    func keypadPressed(_ key: String) {
        if inCall {
            session.pressKeys(key)
        } else {
            dialNumber += key
        }
    }

    func dial() {
        session.dial(dialNumber)
    }

    func saveProfile() {
        do {
            try session.saveProfile(profileText)
            append(SessionLogEntry(kind: .system, text: L("Info saved", "Infos enregistrées")))
            restartAgentIfRunning()
        } catch {
            append(SessionLogEntry(kind: .error, text: L("Couldn't save: ", "Enregistrement impossible : ") + error.localizedDescription))
        }
    }

    func runChecks() async {
        checks = await session.checkStack()
    }

    func clearLog() {
        log.removeAll()
        Task { await session.resetAgentConversation() }
    }

    private func append(_ entry: SessionLogEntry) {
        if case .translation(let original) = entry.kind {
            if let index = log.lastIndex(where: { $0.id == original }) {
                log[index].translation = entry.text
            }
            return
        }
        log.append(entry)
        if entry.kind == .question {
            pendingQuestion = entry.text
            questionPopup = entry.text
            questionOptions = entry.options
            inputMode = .agent
            alertUser(question: entry.text)
        }
        let phoneLost = ["Phone disconnected", "Téléphone déconnecté"].contains { entry.text.hasPrefix($0) }
        if phoneLost || ["AI agent stopped", "Agent IA arrêté"].contains(where: { entry.text.hasPrefix($0) }) {
            agentEnabled = false
        }
        if phoneLost {
            connectedName = nil
        }
    }
}
