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
import HFPCore
import AudioPipeline
import Shared

// MARK: - Configuration

public enum STTEngine: String, Sendable {
    /// whisper.cpp server: multilingual with automatic language detection
    case whisper
    /// Apple SFSpeechRecognizer on-device: single fixed language
    case apple
}

public enum CallAudioMode: String, Sendable {
    /// macOS "Calls from iPhone" + BlackHole virtual devices (works on current macOS)
    case continuity
    /// Bluetooth hands-free SCO audio (refused by recent macOS versions)
    case bluetooth
}

public struct PhoneSessionConfig: Sendable {
    public var audioMode: CallAudioMode
    public var ollamaURL: URL
    public var model: String
    /// Speech locale override (PHONEBT_LOCALE); nil = the agent language's locale
    public var locale: String?
    public var voice: String?
    public var voiceRate: Float
    public var sttEngine: STTEngine
    public var whisperModelPath: String
    /// Language of the other party for Whisper (ISO 639-1), nil = automatic detection
    public var whisperLanguage: String?
    public var whisperPort: Int
    public var profilePath: String
    public var extraInstructionsPath: String?

    public static let dataDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".phonebt").path

    /// Defaults, overridable with environment variables
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let host = env["OLLAMA_HOST"].map { $0.hasPrefix("http") ? $0 : "http://\($0)" } ?? "http://localhost:11434"
        return PhoneSessionConfig(
            audioMode: CallAudioMode(rawValue: env["PHONEBT_AUDIO"] ?? "") ?? .continuity,
            ollamaURL: URL(string: host)!,
            model: env["PHONEBT_MODEL"] ?? "qwen3:8b",
            locale: env["PHONEBT_LOCALE"],
            voice: env["PHONEBT_VOICE"],
            voiceRate: env["PHONEBT_VOICE_RATE"].flatMap(Float.init) ?? 0.52,
            sttEngine: STTEngine(rawValue: env["PHONEBT_STT"] ?? "") ?? .whisper,
            whisperModelPath: env["PHONEBT_WHISPER_MODEL"] ?? "\(dataDirectory)/models/ggml-large-v3-turbo-q5_0.bin",
            whisperLanguage: env["PHONEBT_WHISPER_LANG"].flatMap { $0.isEmpty || $0 == "auto" ? nil : $0 },
            whisperPort: env["PHONEBT_WHISPER_PORT"].flatMap(Int.init) ?? 8178,
            profilePath: env["PHONEBT_PROFILE"] ?? "\(dataDirectory)/profile.md",
            extraInstructionsPath: env["PHONEBT_PROMPT_FILE"]
        )
    }
}

// MARK: - Log

public struct SessionLogEntry: Sendable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case system
        case error
        /// Transcribed speech from the other party, with detected language
        case caller(language: String?)
        /// Agent text for the user (summary, report)
        case agent
        /// What the agent said in the call
        case agentSpoke
        /// The agent needs information from the user
        case question
        /// Instruction typed by the user to the agent
        case user
        /// Text the user had spoken directly in the call
        case userSpoke
        /// DTMF keys sent
        case keys
        /// Translation (agent language) of the entry `of` (shown under it, not as its own row)
        case translation(of: UUID)
    }

    public let id = UUID()
    public let date = Date()
    public let kind: Kind
    public let text: String
    /// Translation into the agent language, when the text is in another language
    public var translation: String?
    /// Clickable answers for a question from the agent
    public var options: [String] = []

    public init(kind: Kind, text: String, options: [String] = []) {
        self.kind = kind
        self.text = text
        self.options = options
    }
}

// MARK: - Session

/// Orchestrates phone connection, audio pipeline, local agent and user interventions.
/// Shared by the CLI and the Mac app. Callbacks may fire on any thread.
public final class PhoneSession: @unchecked Sendable {
    public let config: PhoneSessionConfig
    public var onLog: (@Sendable (SessionLogEntry) -> Void)?
    public var onStateChange: (@Sendable (HFPState?) -> Void)?

    private let bluetoothManager = BluetoothManager()
    private let audioRouter = AudioRouter()
    private let whisperServer: WhisperServer
    private let logger = PhoneBTLogger(category: .app)
    private let lock = NSRecursiveLock()

    private var device: HFPDevice?
    private var deviceEventsTask: Task<Void, Never>?
    private var agent: LocalAgent?
    private var executor: ToolExecutor?
    private var agentListenerTask: Task<Void, Never>?

    private var audioSession: AudioSessionManager?
    private var appleCapture: AudioCapture?
    private var whisperCapture: WhisperCapture?
    private var ttsPlayer: TTSPlayer?
    private var monitor: CallMonitor?
    private var monitorEnabled = true
    private lazy var callLanguage: String? = config.whisperLanguage
    /// Language last heard from the other party (Whisper detection)
    private var lastCallerLanguage: String?
    private var monitorVolume: Float = 0.8
    /// Audio connection attempts for the current call (transfer, then direct SCO)
    private var audioAttempts = 0
    private let continuity = ContinuityCalls()

    public init(config: PhoneSessionConfig = .fromEnvironment()) {
        self.config = config
        self.whisperServer = WhisperServer(port: config.whisperPort, modelPath: config.whisperModelPath)
        // No call yet: the Mac keeps its own speakers and microphone
        continuity.releaseVirtualDefaults()
    }

    /// Default speech locale: PHONEBT_LOCALE, else the agent language's
    public var speechLocale: String { config.locale ?? UILanguage.agent.locale }

    public var state: HFPState? { withLock { device?.currentState } }
    public var isConnected: Bool { state?.connection == .connected }
    public var isAgentRunning: Bool { withLock { agent != nil } }
    public var connectedDeviceName: String? { withLock { device?.deviceName } }

    // MARK: Profile

    public func loadProfile() -> String {
        (try? String(contentsOfFile: config.profilePath, encoding: .utf8)) ?? ""
    }

    public func saveProfile(_ text: String) throws {
        let url = URL(fileURLWithPath: config.profilePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Devices

    public func pairedPhones() -> [DiscoveredDevice] {
        bluetoothManager.getPairedPhones()
    }

    public func scan(duration: TimeInterval = 10) async throws -> [DiscoveredDevice] {
        try await bluetoothManager.scanForDevices(duration: duration)
    }

    public func connect(to selected: DiscoveredDevice) async throws {
        disconnect()
        guard BluetoothManager.isAuthorized else {
            BluetoothManager.requestAuthorization()
            throw SessionError.bluetoothNotAuthorized(BluetoothManager.authorizationStatus)
        }
        guard let btDevice = bluetoothManager.device(forAddress: selected.address) else {
            throw SessionError.deviceNotFound(selected.address)
        }
        guard let newDevice = HFPDevice(bluetoothDevice: btDevice) else {
            throw SessionError.hfpUnavailable(selected.name)
        }

        log(.system, L("Connecting to \(selected.name)… If a code appears on the iPhone and the Mac, check that it matches and accept on both (only once).", "Connexion à \(selected.name)… Si un code s'affiche sur l'iPhone et le Mac, vérifie qu'il est identique et accepte des deux côtés (une seule fois)."))
        try await newDevice.connect()
        withLock { device = newDevice }
        log(.system, L("Connected to \(selected.name)", "Connecté à \(selected.name)"))
        logger.info("AG features (phone): 0x\(String(newDevice.phoneFeatures, radix: 16))")

        let stream = newDevice.eventStream.makeStream()
        let task = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
        withLock { deviceEventsTask = task }
        onStateChange?(newDevice.currentState)

        // Prepare speech recognition in the background so it's ready for the first call
        if config.sttEngine == .whisper {
            Task { await self.prepareWhisper() }
        }
    }

    public func disconnect() {
        stopAgent()
        stopAudioPipeline()
        let (d, t) = withLock { () -> (HFPDevice?, Task<Void, Never>?) in
            defer { device = nil; deviceEventsTask = nil }
            return (device, deviceEventsTask)
        }
        t?.cancel()
        if let d {
            d.disconnect()
            audioRouter.restorePreviousRouting()
            log(.system, L("Disconnected", "Déconnecté"))
        }
        onStateChange?(nil)
    }

    /// Ask for the microphone and system-audio permissions now, not during the first call
    /// (macOS shows its prompt when the capture starts, and the call's first words are lost)
    public func requestAudioPermissions() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard config.audioMode == .continuity, #available(macOS 14.2, *) else { return }
        do {
            // Briefly start a system capture: this triggers the "system audio recording" prompt
            let tap = try SystemAudioTap()
            try tap.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            tap.stop()
        } catch {
            logger.error("System audio permission probe failed: \(error)")
        }
    }

    public func shutdown() {
        disconnect()
        continuity.restoreSystemAudio()
        whisperServer.stop()
    }

    // MARK: Agent

    public func startAgent(autoAnswer: Bool) async throws {
        guard let device = withLock({ self.device }) else { throw SessionError.notConnected }
        stopAgent()

        let client = OllamaClient(baseURL: config.ollamaURL, model: config.model)
        try await client.checkAvailability()

        var extra: String?
        if let path = config.extraInstructionsPath {
            extra = try String(contentsOfFile: path, encoding: .utf8)
        }

        let executor = ToolExecutor(device: device, audioRouter: audioRouter, ttsPlayer: withLock { ttsPlayer })
        executor.actions = self
        executor.onAskUser = { [weak self] question, options in
            self?.log(.question, question, options: options)
        }
        let agent = LocalAgent(
            client: client,
            toolExecutor: executor,
            eventStream: device.eventStream,
            autoAnswer: autoAnswer,
            userProfile: loadProfile(),
            extraInstructions: extra,
            callerActivity: { [weak self] in
                guard let self else { return false }
                return self.withLock { self.whisperCapture }?.isCallerBusy ?? false
            }
        )

        log(.system, L("Loading model \(config.model)…", "Chargement du modèle \(config.model)…"))
        await agent.warmUp()

        let listener = agent.startEventListener { [weak self] response in
            self?.logAgentResponse(response)
        }
        withLock {
            self.executor = executor
            self.agent = agent
            self.agentListenerTask = listener
        }
        log(.system, L("AI agent active", "Agent IA actif") + (autoAnswer ? L(" — answers automatically", " — décroche automatiquement") : ""))
    }

    public func stopAgent() {
        let task = withLock { () -> Task<Void, Never>? in
            defer { agent = nil; executor = nil; agentListenerTask = nil }
            return agentListenerTask
        }
        if let task {
            task.cancel()
            log(.system, L("AI agent stopped", "Agent IA arrêté"))
        }
    }

    /// Instruction or answer from the user to the agent
    public func sendToAgent(_ text: String) async {
        guard let agent = withLock({ self.agent }) else {
            log(.error, L("The agent isn't running", "L'agent n'est pas actif"))
            return
        }
        log(.user, text)
        do {
            logAgentResponse(try await agent.processMessage(text))
        } catch {
            log(.error, L("Agent error: ", "Erreur agent : ") + error.localizedDescription)
        }
    }

    public func resetAgentConversation() async {
        await withLock({ self.agent })?.reset()
        log(.system, L("Agent conversation reset", "Conversation de l'agent réinitialisée"))
    }

    // MARK: Listening in

    /// Hear the call (other party + agent voice) on the Mac's speakers/headphones
    public func setMonitor(enabled: Bool, volume: Float) {
        let m = withLock { () -> CallMonitor? in
            monitorEnabled = enabled
            monitorVolume = volume
            return monitor
        }
        m?.configure(enabled: enabled, volume: volume)
    }

    // MARK: Language

    /// Language spoken by the other party (ISO 639-1), nil to detect it automatically.
    /// Applies immediately, including to the current call.
    public func setCallLanguage(_ code: String?) {
        let capture = withLock { () -> WhisperCapture? in
            callLanguage = code
            return whisperCapture
        }
        capture?.language = code
        log(.system, L("Caller's language: ", "Langue de l'interlocuteur : ") + (code.map { Self.languageName($0) } ?? L("automatic detection", "détection automatique")))
    }

    // MARK: User interventions in the call

    /// Speak text in the call with TTS, bypassing the agent
    /// Language of the call: the one chosen by the user, else the one last heard
    public var callTargetLanguage: String? {
        withLock { callLanguage ?? lastCallerLanguage }
    }

    /// Speak text in the call with TTS, bypassing the agent. Text typed in French is first
    /// translated into the call's language when that language is another one.
    public func say(_ text: String) {
        guard let player = withLock({ ttsPlayer }) else {
            log(.error, L("Call audio not connected — can't speak", "Audio de l'appel non connecté — impossible de parler"))
            return
        }
        let target = callTargetLanguage
        let userLanguage = UILanguage.agent.rawValue
        let typedLanguage = TTSPlayer.detectLanguage(text) ?? userLanguage
        let agent = withLock { self.agent }
        Task {
            var spoken = text
            var original: String?
            if let target, !target.hasPrefix(userLanguage), typedLanguage.hasPrefix(userLanguage) {
                do {
                    spoken = try await self.translate(text, from: userLanguage, to: target, priority: .interactive)
                    original = text
                } catch {
                    self.log(.error, L("Translation failed (\(error.localizedDescription)) — spoken as typed", "Traduction impossible (\(error.localizedDescription)) — dit tel quel"))
                }
            }
            var entry = SessionLogEntry(kind: .userSpoke, text: spoken)
            entry.translation = original
            self.logger.info("[userSpoke] \(spoken)\(original.map { " (fr: \($0))" } ?? "")")
            self.onLog?(entry)
            do {
                try await player.speak(spoken, language: original == nil ? nil : target)
            } catch {
                self.log(.error, L("Speech synthesis failed: ", "Synthèse vocale échouée : ") + error.localizedDescription)
            }
            await agent?.addNote("The user said this to the caller themselves: \"\(spoken)\"\(original.map { " (typed as: \($0))" } ?? "")")
        }
    }

    /// Press phone keys (DTMF), e.g. "1" or "123456789#"
    public func pressKeys(_ raw: String) {
        guard let device = withLock({ self.device }) else {
            log(.error, L("Phone not connected", "Téléphone non connecté"))
            return
        }
        let digits = ToolExecutor.dtmfDigits(raw)
        guard !digits.isEmpty else { return }
        log(.keys, String(digits))
        Task {
            // Continuity call: the Phone app's keypad reaches the network, Bluetooth DTMF didn't
            if await self.sendKeys(digits) { return }
            for (i, d) in digits.enumerated() {
                if i > 0 { try? await Task.sleep(nanoseconds: 350_000_000) }
                do { try device.sendDTMF(String(d)) } catch {
                    self.log(.error, L("Key \(d): ", "Touche \(d) : ") + error.localizedDescription)
                    return
                }
            }
        }
        if let agent = withLock({ self.agent }) {
            Task {
                await agent.keysPressed(String(digits), byUser: true)
                await agent.addNote("The user pressed the keys \(String(digits)) themselves")
            }
        }
    }

    public func dial(_ number: String) {
        do { try placeCall(number) } catch { log(.error, L("Can't call: ", "Appel impossible : ") + error.localizedDescription) }
    }

    public func answer() {
        do { try acceptCall() } catch { log(.error, L("Can't answer: ", "Impossible de décrocher : ") + error.localizedDescription) }
    }

    public func hangup() {
        do { try endCall() } catch { log(.error, L("Can't hang up: ", "Impossible de raccrocher : ") + error.localizedDescription) }
    }

    // MARK: Diagnostics

    public struct CheckResult: Sendable {
        public let label: String
        public let ok: Bool
        public let detail: String
    }

    public func checkStack() async -> [CheckResult] {
        var results: [CheckResult] = []

        results.append(.init(
            label: "Bluetooth",
            ok: BluetoothManager.isAuthorized,
            detail: BluetoothManager.isAuthorized
                ? L("Allowed", "Autorisé")
                : L("Access \(BluetoothManager.authorizationStatus) — System Settings › Privacy & Security › Bluetooth › turn on PhoneBT", "Accès \(BluetoothManager.authorizationStatus) — Réglages Système › Confidentialité et sécurité › Bluetooth › active PhoneBT")
        ))

        if config.audioMode == .continuity {
            let devices = continuity.findDevices()
            results.append(.init(
                label: L("Call audio", "Audio des appels"),
                ok: devices != nil,
                detail: devices.map { L("Continuity via \($0.fromCall.name) / \($0.toCall.name)", "Continuité via \($0.fromCall.name) / \($0.toCall.name)") }
                    ?? L("BlackHole missing: brew install --cask blackhole-2ch blackhole-16ch, then restart the Mac", "BlackHole manquant : brew install --cask blackhole-2ch blackhole-16ch, puis redémarre le Mac")
            ))
            let ax = ContinuityCalls.isAccessibilityTrusted
            results.append(.init(
                label: L("Accessibility", "Accessibilité"),
                ok: ax,
                detail: ax ? L("Allowed (dial / answer automatically)", "Autorisé (composer / décrocher automatiquement)")
                    : L("Not allowed for this version of PhoneBT. If PhoneBT is already switched on in System Settings, that entry is for a previous build: click \"Reset permission\", then switch PhoneBT on again.",
                        "Pas autorisé pour cette version de PhoneBT. Si PhoneBT est déjà coché dans les Réglages, c'est l'autorisation d'une ancienne version : clique « Réinitialiser l'autorisation », puis réactive PhoneBT.")
            ))
        }

        do {
            try await OllamaClient(baseURL: config.ollamaURL, model: config.model).checkAvailability()
            results.append(.init(label: "LLM", ok: true, detail: "\(config.model) via Ollama"))
        } catch {
            results.append(.init(label: "LLM", ok: false, detail: error.localizedDescription))
        }

        switch config.sttEngine {
        case .whisper:
            let modelOK = FileManager.default.fileExists(atPath: config.whisperModelPath)
            let binOK = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
                .contains { FileManager.default.isExecutableFile(atPath: $0) }
            results.append(.init(
                label: "Transcription",
                ok: modelOK && binOK,
                detail: !binOK ? L("whisper-server missing: brew install whisper-cpp", "whisper-server manquant : brew install whisper-cpp")
                    : !modelOK ? L("Model missing: ", "Modèle manquant : ") + config.whisperModelPath
                    : L("Local Whisper, automatic language detection", "Whisper local, détection de langue auto")
            ))
        case .apple:
            let ok = AudioCapture.supportsOnDevice(locale: Locale(identifier: speechLocale))
            results.append(.init(
                label: "Transcription",
                ok: ok,
                detail: ok ? L("Apple offline (\(speechLocale))", "Apple hors-ligne (\(speechLocale))") : L("Turn on \(speechLocale) Dictation in System Settings › Keyboard", "Active la Dictée \(speechLocale) dans Réglages Système › Clavier")
            ))
        }

        do {
            let code = String(speechLocale.prefix(2))
            let voices = TTSPlayer.availableVoices(language: code)
            results.append(.init(
                label: L("Voice", "Voix"),
                ok: !voices.isEmpty,
                detail: voices.first.map { "\($0.name)" }
                    ?? L("No \(code) voice: System Settings › Accessibility › Spoken Content › System Voice", "Aucune voix \(code) : Réglages Système › Accessibilité › Contenu énoncé › Voix du système")
            ))
        }
        return results
    }

    // MARK: - Private

    private func handle(_ event: HFPEvent) {
        let state = withLock { device?.currentState }
        onStateChange?(state)

        switch event {
        case .incomingCall(let number):
            log(.system, L("📞 Incoming call from ", "📞 Appel entrant de ") + (number ?? L("unknown number", "numéro inconnu")))
        case .callAlerting:
            log(.system, L("Ringing…", "Ça sonne…"))
            if config.audioMode == .bluetooth {
                requestCallAudio()
            } else {
                // Start listening while it rings: capture takes ~2 s to start, and the
                // first words after pick-up (often the voice menu's greeting) were lost
                startContinuityAudio()
            }
        case .callActive:
            log(.system, L("Call in progress", "Appel en cours"))
            if config.audioMode == .bluetooth {
                requestCallAudio()
            } else {
                startContinuityAudio()
            }
        case .callEnded:
            withLock { audioAttempts = 0 }
            log(.system, L("Call ended", "Appel terminé"))
            if config.audioMode == .continuity {
                stopAudioPipeline()
                continuity.restoreSystemAudio()
            }
        case .scoFailed(let status):
            let attempts = withLock { audioAttempts }
            logger.info("SCO refused (status \(status)) after attempt \(attempts)")
            if attempts < 2 {
                // Second strategy: open the SCO link directly instead of asking for a transfer
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.requestCallAudio()
                }
            } else {
                log(.error, L("The Mac couldn't open the call's audio channel (code \(status)). The sound stays on the iPhone.", "Le Mac n'a pas pu ouvrir le canal audio de l'appel (code \(status)). Le son reste sur l'iPhone."))
            }
        case .error(let message):
            log(.error, message)
        case .scoConnected:
            log(.system, L("🔊 Audio connected", "🔊 Audio connecté"))
            if config.audioMode == .bluetooth { startAudioPipeline() }
        case .scoDisconnected:
            log(.system, L("🔇 Audio disconnected", "🔇 Audio déconnecté"))
            stopAudioPipeline()
            audioRouter.restorePreviousRouting()
        case .callerSpeech(let text, let language):
            if let language { withLock { lastCallerLanguage = language } }
            let entry = log(.caller(language: language), text)
            translateIfNeeded(entry, language: language)
        case .disconnected:
            log(.error, L("Phone disconnected", "Téléphone déconnecté"))
            stopAgent()
            stopAudioPipeline()
            continuity.restoreSystemAudio()
            withLock { device = nil }
            onStateChange?(nil)
        default:
            break
        }
    }

    /// Ask the phone to route the call audio to the Mac (SCO), if not already done
    private func requestCallAudio() {
        guard let device = withLock({ self.device }), device.currentState.audio != .connected else { return }
        let attempt = withLock { () -> Int in
            audioAttempts += 1
            return audioAttempts
        }
        guard attempt <= 2 else { return }
        do {
            if attempt == 1 {
                logger.info("Audio attempt 1: transferAudioToComputer")
                try device.transferAudioToComputer()
            } else {
                logger.info("Audio attempt 2: connectSCO")
                try device.connectAudio()
            }
        } catch {
            log(.error, L("Audio request failed: ", "Demande audio échouée : ") + error.localizedDescription)
        }
    }

    private func prepareWhisper() async {
        do {
            if !(await whisperServer.isRunning()) {
                log(.system, L("Starting Whisper transcription…", "Démarrage de la transcription Whisper…"))
            }
            try await whisperServer.ensureRunning()
        } catch {
            log(.error, "Whisper: \(error.localizedDescription)")
        }
    }

    private func startAudioPipeline(attempt: Int = 0) {
        guard let device = withLock({ self.device }), device.currentState.audio == .connected else { return }

        // The CoreAudio device for the SCO link can take a moment to appear
        guard let scoDevice = AudioDeviceManager().getBluetoothDevices().first(where: { $0.hasInput && $0.hasOutput }) else {
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.startAudioPipeline(attempt: attempt + 1)
                }
            } else {
                let all = AudioDeviceManager().getAllDevices().map { "\($0.name) (bt=\($0.isBluetooth), in=\($0.hasInput), out=\($0.hasOutput))" }
                logger.error("No SCO device. Audio devices: \(all.joined(separator: "; "))")
                log(.error, L("No Bluetooth (SCO) audio device found", "Aucun périphérique audio Bluetooth (SCO) trouvé"))
            }
            return
        }
        // The engine targets the SCO device explicitly; the Mac's default output stays
        // untouched so the user can listen to the call on it.
        startCallAudio(
            input: scoDevice, output: scoDevice, voiceProcessing: true,
            listenOn: CallMonitor.listeningDevice(avoidingUIDs: [scoDevice.uid]),
            device: device
        )
    }

    /// Continuity call is active: wire FaceTime's audio (via BlackHole) to the agent
    private func startContinuityAudio() {
        guard let device = withLock({ self.device }), withLock({ audioSession }) == nil else { return }
        guard let devices = continuity.findDevices() else {
            log(.error, L("BlackHole not found — install it (brew install --cask blackhole-2ch blackhole-16ch), then restart the Mac", "BlackHole introuvable — installe-le (brew install --cask blackhole-2ch blackhole-16ch) puis redémarre le Mac"))
            return
        }
        // In case the call was answered manually on the Mac
        continuity.routeSystemAudio(to: devices)
        let listenOn = continuity.userOutputDevice
            ?? CallMonitor.listeningDevice(avoidingUIDs: [devices.fromCall.uid, devices.toCall.uid])

        if startCallAudio(
            input: devices.fromCall, output: devices.toCall, voiceProcessing: false,
            listenOn: listenOn, systemCapture: continuity.capturesSystemAudio, device: device
        ) {
            // Tell the agent (and the UI) that it can now hear and speak
            device.eventStream.emit(.scoConnected)
        }
    }

    @discardableResult
    private func startCallAudio(
        input: AudioDeviceInfo, output: AudioDeviceInfo, voiceProcessing: Bool,
        listenOn: AudioDeviceID?, systemCapture: Bool = false, device: HFPDevice
    ) -> Bool {
        var session = AudioSessionManager()
        do {
            if systemCapture, #available(macOS 14.2, *) {
                // FaceTime plays the call on the user's speakers; the agent hears it from there
                do {
                    try session.configureSystemCapture(outputDeviceUID: output.uid)
                    try session.start()
                } catch {
                    logger.error("System capture unavailable: \(error) — falling back to \(input.name)")
                    session.stop()
                    session = AudioSessionManager()
                    continuity.systemCaptureUsable = false
                    if let devices = continuity.findDevices() { continuity.routeSystemAudio(to: devices) }
                    try session.configure(inputDeviceUID: input.uid, outputDeviceUID: output.uid, voiceProcessing: voiceProcessing)
                    try session.start()
                }
            } else {
                try session.configure(inputDeviceUID: input.uid, outputDeviceUID: output.uid, voiceProcessing: voiceProcessing)
                try session.start()
            }
        } catch {
            log(.error, L("Audio start failed: ", "Démarrage audio échoué : ") + error.localizedDescription)
            return false
        }

        let player = TTSPlayer(
            sessionManager: session, language: speechLocale,
            voiceIdentifier: config.voice, rate: config.voiceRate
        )

        // Listen in on the Mac: other party (input tap) + voice sent to the call
        var newMonitor: CallMonitor?
        do {
            let m = try CallMonitor(
                callerFormat: session.inputFormat,
                voiceFormat: session.playbackFormat,
                outputDeviceID: listenOn,
                // FaceTime ducks other apps by ~20 dB during a Continuity call
                boostDecibels: config.audioMode == .continuity ? 20 : 0
            )
            let (enabled, volume) = withLock { (monitorEnabled, monitorVolume) }
            m.configure(enabled: enabled, volume: volume)
            try m.start()
            // With system capture, FaceTime already plays the other party on the speakers
            if !session.capturesSystemAudio {
                session.addInputHandler { [weak m] buffer in m?.playCaller(buffer) }
            }
            player.onPlayback = { [weak m] buffer in m?.playVoice(buffer) }
            newMonitor = m
        } catch {
            log(.error, L("Listening to the call on the Mac is unavailable: ", "Écoute de l'appel sur le Mac indisponible : ") + error.localizedDescription)
        }

        watchInputLevel(session: session, deviceName: session.capturesSystemAudio ? L("system audio", "audio du système") : input.name)

        withLock {
            audioSession = session
            ttsPlayer = player
            monitor = newMonitor
            executor?.ttsPlayer = player
        }

        Task {
            await self.startCapture(session: session, player: player, device: device)
        }
        logger.info("Audio pipeline started: in \(input.name), out \(output.name)")
        return true
    }

    /// Logs the call input level, and warns the user if no call audio reaches the Mac
    private func watchInputLevel(session: AudioSessionManager, deviceName: String) {
        let meter = LevelMeter()
        session.addInputHandler { buffer in meter.add(buffer) }
        Task { [weak self, weak session] in
            var heardSomething = false
            for tick in 1...12 {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, let session, self.withLock({ self.audioSession === session }) else { return }
                let peak = meter.takePeak()
                let monitorStatus = self.withLock { self.monitor?.statusDescription } ?? "no monitor"
                self.logger.info("Call input level (\(deviceName)): peak \(String(format: "%.4f", peak)), \(monitorStatus), \(session.voiceStatusDescription)")
                if tick == 4 || tick == 8 {
                    // Which app records which microphone (the call app must use the agent's voice device)
                    self.logger.info("Recording apps: \(AudioDeviceManager().recordingProcesses().joined(separator: "; "))")
                }
                if tick <= 2 {
                    let manager = AudioDeviceManager()
                    let output = manager.getAllDevices().first { $0.id == manager.getDefaultOutputDevice() }?.name ?? "?"
                    self.logger.info("Default output: \(output); devices in use: \(manager.runningDeviceNames().joined(separator: ", "))")
                }
                if peak > 0.001 { heardSomething = true }
                if tick == 4 && !heardSomething {
                    if session.capturesSystemAudio {
                        self.log(.error, L("The agent can't hear the call: allow PhoneBT in System Settings › Privacy & Security › Screen & System Audio Recording (\"System Audio Recording Only\" section), then relaunch PhoneBT. If you can't hear the call either, its audio stayed on the iPhone.", "L'agent n'entend pas l'appel : autorise PhoneBT dans Réglages Système › Confidentialité et sécurité › Enregistrement de l'écran et de l'audio système (section « Audio système uniquement »), puis relance PhoneBT. Si tu n'entends pas non plus l'appel, son audio est resté sur l'iPhone."))
                    } else {
                        self.log(.error, L("No call audio reaches the Mac (\(deviceName) is silent). The call audio probably stayed on the iPhone: tap \"Audio\" on the iPhone's call screen and choose the Mac, or check that FaceTime's output is \"\(deviceName)\".", "Aucun son de l'appel n'arrive sur le Mac (\(deviceName) est silencieux). Le son de l'appel est probablement resté sur l'iPhone : touche « Audio » dans l'écran d'appel de l'iPhone et choisis le Mac, ou vérifie que la sortie de FaceTime est « \(deviceName) »."))
                    }
                }
            }
        }
    }

    private func startCapture(session: AudioSessionManager, player: TTSPlayer, device: HFPDevice) async {
        if config.sttEngine == .whisper {
            await prepareWhisper()
            if await whisperServer.isRunning() {
                let capture = WhisperCapture(sessionManager: session, serverURL: whisperServer.url)
                capture.language = withLock { callLanguage }
                capture.onTranscription = { text, language in
                    device.eventStream.emit(.callerSpeech(text, language: language))
                }
                // Don't transcribe our own voice
                player.onSpeakingChanged = { [weak capture] speaking in
                    capture?.isMuted = speaking
                }
                do {
                    try capture.start()
                    withLock { whisperCapture = capture }
                    return
                } catch {
                    log(.error, L("Whisper capture failed: ", "Capture Whisper échouée : ") + error.localizedDescription)
                }
            }
            log(.error, L("Whisper unavailable — Apple transcription (\(speechLocale) only)", "Whisper indisponible — transcription Apple (\(speechLocale) uniquement)"))
        }

        let capture = AudioCapture(sessionManager: session, locale: Locale(identifier: speechLocale))
        let language = String(speechLocale.prefix(2))
        capture.onTranscription = { text in
            device.eventStream.emit(.callerSpeech(text, language: language))
        }
        do {
            try capture.start()
            withLock { appleCapture = capture }
        } catch {
            log(.error, L("Audio capture failed: ", "Capture audio échouée : ") + error.localizedDescription)
        }
    }

    private func stopAudioPipeline() {
        let (apple, whisper, session, mon) = withLock { () -> (AudioCapture?, WhisperCapture?, AudioSessionManager?, CallMonitor?) in
            defer {
                monitor = nil
                appleCapture = nil
                whisperCapture = nil
                audioSession = nil
                ttsPlayer = nil
                executor?.ttsPlayer = nil
            }
            return (appleCapture, whisperCapture, audioSession, monitor)
        }
        mon?.stop()
        apple?.stop()
        whisper?.stop()
        session?.stop()
    }

    private func logAgentResponse(_ raw: String) {
        // Small models sometimes imitate the input tags ("[NOTE] …")
        let response = raw.replacingOccurrences(
            of: #"^\s*\[(NOTE|PHONE EVENT|CALLER SPEECH[^\]]*)\]\s*"#, with: "", options: .regularExpression
        )
        guard !response.isEmpty else { return }
        // Lines prefixed by 🗣️ are what the agent said in the call
        let spoken = response.components(separatedBy: "\n").filter { $0.hasPrefix("🗣️") }
        if spoken.isEmpty {
            log(.agent, response)
        } else {
            for line in spoken {
                let text = line.replacingOccurrences(of: "🗣️", with: "").trimmingCharacters(in: .whitespaces)
                let entry = log(.agentSpoke, text)
                translateIfNeeded(entry, language: TTSPlayer.detectLanguage(text))
            }
        }
    }

    /// Translate with the local model (phone sentences: short, spoken style)
    private func translate(_ text: String, from source: String, to target: String, priority: OllamaPriority = .background) async throws -> String {
        let client = OllamaClient(baseURL: config.ollamaURL, model: config.model)
        let reply = try await client.chat(messages: [
            ChatMessage(role: "system", content: "You translate a phone conversation. Translate the user's text from \(Self.languageName(source, in: .en)) into \(Self.languageName(target, in: .en)), in a natural, polite spoken style. Keep proper names, numbers and brands as they are. Reply with the translation only, without quotes or comments."),
            ChatMessage(role: "user", content: text),
        ], tools: [], priority: priority)
        let translation = OllamaClient.stripThinking(reply.content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty else { throw SessionError.translationFailed }
        return translation
    }

    /// Name of a language (ISO 639-1 code) in the app language, or in `language`
    public static func languageName(_ code: String, in language: UILanguage = .current) -> String {
        let names: [String: (en: String, fr: String)] = [
            "ar": ("Arabic", "arabe"), "de": ("German", "allemand"), "en": ("English", "anglais"),
            "es": ("Spanish", "espagnol"), "fr": ("French", "français"), "he": ("Hebrew", "hébreu"),
            "it": ("Italian", "italien"), "pt": ("Portuguese", "portugais"), "ru": ("Russian", "russe"),
        ]
        guard let name = names[String(code.prefix(2))] else { return code }
        return language == .fr ? name.fr : name.en
    }

    @discardableResult
    private func log(_ kind: SessionLogEntry.Kind, _ text: String, options: [String] = []) -> SessionLogEntry {
        logger.info("[\(kind)] \(text)\(options.isEmpty ? "" : " options: \(options)")")
        let entry = SessionLogEntry(kind: kind, text: text, options: options)
        onLog?(entry)
        return entry
    }

    /// Translate into French what is said in the call in another language (shown under it)
    private func translateIfNeeded(_ entry: SessionLogEntry, language: String?) {
        let target = UILanguage.agent.rawValue
        guard let language, !language.hasPrefix(target),
              entry.text.count > 2 else { return }
        Task { [weak self] in
            do {
                guard let translation = try await self?.translate(entry.text, from: language, to: target),
                      let self else { return }
                self.logger.info("[translation] \(translation)")
                self.onLog?(SessionLogEntry(kind: .translation(of: entry.id), text: translation))
            } catch {
                self?.logger.error("Translation failed: \(error)")
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

public enum SessionError: Error, LocalizedError {
    case notConnected
    case deviceNotFound(String)
    case hfpUnavailable(String)
    case bluetoothNotAuthorized(String)
    case invalidNumber(String)
    case blackHoleMissing
    case translationFailed

    public var errorDescription: String? {
        switch self {
        case .notConnected: return L("No phone connected", "Aucun téléphone connecté")
        case .deviceNotFound(let address): return L("Device not found (\(address))", "Appareil introuvable (\(address))")
        case .hfpUnavailable(let name): return L("\(name) doesn't offer the hands-free profile (HFP)", "\(name) ne propose pas le profil mains-libres (HFP)")
        case .invalidNumber(let n): return L("Invalid number: ", "Numéro invalide : ") + n
        case .translationFailed: return L("empty translation", "traduction vide")
        case .blackHoleMissing:
            return L("BlackHole isn't installed: brew install --cask blackhole-2ch blackhole-16ch, then restart the Mac", "BlackHole n'est pas installé : brew install --cask blackhole-2ch blackhole-16ch, puis redémarre le Mac")
        case .bluetoothNotAuthorized(let status):
            return L("macOS blocks PhoneBT's Bluetooth access (\(status)). Accept the permission request, or turn on PhoneBT in System Settings › Privacy & Security › Bluetooth, then try again.", "macOS bloque l'accès Bluetooth de PhoneBT (\(status)). Accepte la demande d'autorisation, ou active PhoneBT dans Réglages Système › Confidentialité et sécurité › Bluetooth, puis réessaie.")
        }
    }
}


// MARK: - Call control used by the agent's tools

extension PhoneSession: CallActions {
    public func placeCall(_ number: String) throws {
        guard let device = withLock({ self.device }) else { throw SessionError.notConnected }
        let sanitized = number.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
        guard !sanitized.isEmpty else { throw SessionError.invalidNumber(number) }

        switch config.audioMode {
        case .bluetooth:
            try device.dial(number: sanitized)
            log(.system, L("Calling \(sanitized)…", "Appel de \(sanitized)…"))

        case .continuity:
            guard let devices = continuity.findDevices() else { throw SessionError.blackHoleMissing }
            // Route FaceTime's audio before the call starts
            continuity.routeSystemAudio(to: devices)
            device.eventStream.emit(.callDialing(number: sanitized))
            log(.system, L("Calling \(sanitized) through the iPhone (Continuity)…", "Appel de \(sanitized) via l'iPhone (Continuité)…"))
            Task {
                let started = { [weak device] () -> Bool in
                    guard let call = device?.currentState.call else { return false }
                    return call == .alerting || call == .active
                }
                if !(await continuity.dial(sanitized, until: started)) && !started() {
                    log(.error, L("I couldn't click \"Call\" — click it in the FaceTime window (and allow PhoneBT in Accessibility)", "Je n'ai pas pu cliquer « Appeler » — clique-le dans la fenêtre FaceTime (et autorise PhoneBT dans Accessibilité)"))
                }
                // The call never went through: give the Mac its audio devices back
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                let call = device.currentState.call
                if call == .idle || call == .dialing, self.withLock({ self.audioSession }) == nil {
                    self.continuity.restoreSystemAudio()
                }
            }
        }
    }

    public func acceptCall() throws {
        guard let device = withLock({ self.device }) else { throw SessionError.notConnected }
        switch config.audioMode {
        case .bluetooth:
            try device.acceptCall()
            log(.system, L("Call answered", "Appel décroché"))

        case .continuity:
            guard let devices = continuity.findDevices() else { throw SessionError.blackHoleMissing }
            continuity.routeSystemAudio(to: devices)
            Task {
                if await continuity.answer() {
                    log(.system, L("Call answered on the Mac", "Appel décroché sur le Mac"))
                } else {
                    log(.error, L("I couldn't find the \"Accept\" button — click it on the Mac's call notification", "Je n'ai pas trouvé le bouton « Accepter » — clique-le sur la notification d'appel du Mac"))
                }
            }
        }
    }

    public func sendKeys(_ digits: [Character]) async -> Bool {
        guard config.audioMode == .continuity else { return false }
        return await continuity.pressKeypad(digits)
    }

    public func endCall() throws {
        if let device = withLock({ self.device }) {
            // Hangs up on the iPhone, which ends the Continuity call too
            try device.endCall()
        } else if config.audioMode == .continuity {
            Task { await continuity.hangUp() }
        } else {
            throw SessionError.notConnected
        }
        if config.audioMode == .continuity {
            stopAudioPipeline()
            continuity.restoreSystemAudio()
        }
    }
}


/// Peak level of the audio buffers seen since the last read
private final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    func add(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        var m: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            for i in 0..<Int(buffer.frameLength) { m = max(m, abs(data[c][i])) }
        }
        lock.lock(); peak = max(peak, m); lock.unlock()
    }

    func takePeak() -> Float {
        lock.lock(); defer { peak = 0; lock.unlock() }
        return peak
    }
}
