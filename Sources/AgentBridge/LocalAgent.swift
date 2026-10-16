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
import Shared

/// Local LLM agent (via Ollama) that manages phone calls through a tool-use conversation loop.
/// Being an actor, user commands and phone events are processed one at a time.
public actor LocalAgent {
    private let client: OllamaClient
    private let toolExecutor: ToolExecutor
    private let eventStream: HFPEventStream
    private let autoAnswer: Bool
    private let logger = PhoneBTLogger(category: .agent)

    private var conversationHistory: [ChatMessage] = []
    /// Digits the agent may type: from the user's profile and messages (never invented)
    private var knownDigits: String
    /// Direction of the current call: true when we placed it, false when it came in, nil without a call
    private var outgoingCall: Bool?
    /// The other party has said something during the current call
    private var heardCaller = false
    /// An IVR (voice menu) answered the current call: listen to whole menus, press keys, don't talk
    private var ivrMode = false
    /// Menu fragments heard since the last pause (Whisper splits a menu at every short pause)
    private var pendingMenu: [String] = []
    private var pendingMenuLanguage: String?
    private var menuFlushTask: Task<Void, Never>?
    /// The voice menu asked for a spoken answer ("say in a few words…")
    private var menuWantsSpeech = false
    /// Pause after the last transcribed fragment before treating the message as complete
    private let menuPause: UInt64 = 1_500_000_000
    /// A person has spoken in the current outgoing call ("allô ?", "Dana speaking…")
    private var humanConfirmed = false
    /// Is the other party talking (or being transcribed) right now?
    private let callerActivity: (@Sendable () -> Bool)?
    private let systemPrompt: String
    private let maxHistoryMessages = 40

    public static let baseSystemPrompt = """
        You are a phone assistant acting ON BEHALF of the user (the person you work for, who \
        follows you from their computer). You place and receive calls through their phone \
        connected over Bluetooth. The "caller" is the person or voice server on the line — \
        not the user.

        Messages you receive:
        - Messages without a prefix: instructions or answers from the user.
        - [CALLER SPEECH lang=xx call=outgoing|incoming] "...": transcription of what the caller \
        says (xx = detected language: en, fr, es…). The transcription may contain errors. If it \
        is followed by (MENU), a voice server is reading options.
        - [PHONE EVENT]: phone event (incoming call, audio connected, call ended…).
        - [NOTE]: context (e.g. what the user said themselves in the call).

        Rules during a call:
        - To talk to the caller, ALWAYS use the say_to_caller tool: it is the only way they can \
        hear you. Never repeat what the caller just said.
        - Answer in the caller's language (lang field) and pass it in the language parameter of \
        say_to_caller, whatever that language is.
        - Short, natural sentences, as when speaking (one or two sentences), no emoji, no \
        markdown, no lists.
        - Voice server (automated menu): listen to the options ("for X, press 1", "pour X, \
        tapez 1") and choose with send_dtmf the one that serves the mission. If you are asked to \
        enter a number (ID, customer number, date…), send it with send_dtmf, followed by # if \
        requested. Don't talk to a voice server unless it asks for a spoken answer.
        - If you have nothing to say (the voice server is still talking, hold music, incomplete \
        sentence), answer only with the word WAIT, without any tool.
        - If you are missing information or a decision, use ask_user (with options when there \
        are possible choices), then politely ask a human caller to hold on. Never make up \
        information: no customer number, code or identity. When a voice server asks for an \
        identifier you don't have, use ask_user.
        - Only share the user's personal data when it is needed for the mission and requested.
        - When the mission is done or the caller says goodbye, say goodbye, then use end_call, \
        and give the user a short summary.

        Your answers to the user never start with a bracketed prefix. For a call you placed \
        yourself, there is nothing to pick up: "call active" means the other party answered.

        When the user asks you to call someone, use dial_number and remember the mission. \
        Outgoing call: LISTEN FIRST, never speak first. Most service numbers (short codes, \
        1-800…) answer with a voice server: listen to the options and navigate the menu with \
        send_dtmf, choosing at each step the option closest to the mission; if the menu isn't \
        finished, answer WAIT. Only speak when a human answers ("hello", "allô", "this is Dana, \
        how can I help?") or a voice server explicitly asks you to speak. Then introduce yourself \
        once and state the reason for your call directly, for example "Hello, I'm John Smith's \
        assistant, I'm calling about…". Never ask the other party what the call is about or \
        what you can do for them. A voice menu reaches you in full (FULL MENU): then choose ONE \
        key with send_dtmf. If no option clearly matches the mission, or if you don't know the \
        mission, use ask_user listing the options translated into {USER_LANGUAGE}, and wait for \
        the answer. If the call ends without success (busy, no answer), tell the user. With the \
        user, speak {USER_LANGUAGE} (also in ask_user), be concise and report clearly.
        """

    public init(
        client: OllamaClient,
        toolExecutor: ToolExecutor,
        eventStream: HFPEventStream,
        autoAnswer: Bool = false,
        userProfile: String? = nil,
        extraInstructions: String? = nil,
        callerActivity: (@Sendable () -> Bool)? = nil
    ) {
        self.callerActivity = callerActivity
        self.knownDigits = Self.digitsOnly(userProfile ?? "")
        self.client = client
        self.toolExecutor = toolExecutor
        self.eventStream = eventStream
        self.autoAnswer = autoAnswer
        self.systemPrompt = Self.makeSystemPrompt(
            autoAnswer: autoAnswer, userProfile: userProfile, extraInstructions: extraInstructions
        )
    }

    public static func makeSystemPrompt(autoAnswer: Bool, userProfile: String?, extraInstructions: String?) -> String {
        var prompt = baseSystemPrompt
        if autoAnswer {
            prompt += """


                Auto-answer mode: INCOMING calls are picked up automatically. For an incoming \
                call, as soon as audio is connected, greet the caller in {USER_LANGUAGE} with \
                say_to_caller ("Hello, I'm …'s assistant"), only once, and ask what the call is \
                about; then continue in the caller's language. Don't \
                do this for a call you placed yourself.
                """
        }
        if let profile = userProfile?.trimmingCharacters(in: .whitespacesAndNewlines), !profile.isEmpty {
            prompt += "\n\nAbout the user (to use for their requests):\n\(profile)"
        }
        if let extra = extraInstructions?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            prompt += "\n\nSpecific instructions:\n\(extra)"
        }
        return prompt.replacingOccurrences(of: "{USER_LANGUAGE}", with: UILanguage.agent.englishName)
    }

    /// Load the model into memory so the first call doesn't wait
    public func warmUp() async {
        _ = try? await client.chat(messages: [ChatMessage(role: "user", content: "ok")], tools: [])
    }

    /// Process a user message through the agent loop, returning the final text response
    public func processMessage(_ userMessage: String) async throws -> String {
        conversationHistory.append(ChatMessage(role: "user", content: userMessage))
        knownDigits += " " + Self.digitsOnly(userMessage)
        return try await runAgentLoop(speakFallback: false)
    }

    /// Inject a system event (e.g., incoming call notification) into the conversation
    public func injectEvent(_ eventDescription: String) async throws -> String {
        conversationHistory.append(ChatMessage(role: "user", content: "[PHONE EVENT] \(eventDescription)"))
        return try await runAgentLoop(speakFallback: false)
    }

    /// Inject caller speech. If the model answers in plain text instead of using
    /// say_to_caller, that text is spoken anyway so the caller always gets a reply.
    public func injectCallerSpeech(_ text: String, language: String? = nil, completeMenu: Bool = false) async throws -> String {
        heardCaller = true
        var attributes = language.map { " lang=\($0)" } ?? ""
        if let outgoingCall { attributes += outgoingCall ? " call=outgoing" : " call=incoming" }
        let tag = "[CALLER SPEECH\(attributes)]"
        let menu: String
        if completeMenu {
            menu = " (FULL MENU) — voice server: if an option clearly matches the mission, press it with send_dtmf (a single key, without speaking). If you're unsure, don't know the mission, or it asks for an identifier you don't have: ask_user with the options translated (e.g. '1 — service for this number'). If the message expects no key: WAIT"
        } else if ivrMode || Self.looksLikeMenu(text) {
            menu = " (MENU) — voice server: choose the option with send_dtmf without speaking, or answer WAIT if the menu isn't finished"
        } else {
            menu = ""
        }
        conversationHistory.append(ChatMessage(role: "user", content: "\(tag) \"\(text)\"\(menu)"))
        // Never read the model's plain text aloud to a voice menu
        return try await runAgentLoop(speakFallback: !ivrMode)
    }

    /// Caller speech entry point: in a voice menu, wait for the whole menu (a pause) before
    /// asking the model, so it hears every option before pressing a key.
    func receiveCallerSpeech(_ text: String, language: String?, onResponse: @escaping @Sendable (String) -> Void) async throws -> String? {
        if Self.looksLikeHuman(text) {
            if ivrMode { logger.info("Human detected — leaving IVR mode") }
            ivrMode = false
            humanConfirmed = true
            let earlier = takePendingMenu()
            let combined = earlier.map { "\($0) … \(text)" } ?? text
            return try await injectCallerSpeech(combined, language: language)
        }
        // Outgoing call: assume a voice server until a person clearly speaks (service numbers
        // almost always start with a recording, and Whisper may miss its first words)
        if outgoingCall == true && (!humanConfirmed || Self.looksLikeIVR(text)) {
            if !ivrMode { logger.info("Listening as IVR — waiting for complete messages") }
            humanConfirmed = false  // e.g. transferred back to a recording
            ivrMode = true
            heardCaller = true
            pendingMenu.append(text)
            pendingMenuLanguage = language ?? pendingMenuLanguage
            menuFlushTask?.cancel()
            menuFlushTask = Task { [weak self, menuPause, callerActivity] in
                try? await Task.sleep(nanoseconds: menuPause)
                // Let a sentence still being spoken/transcribed finish — but not forever: hold
                // music or a recording that keeps talking must not delay the answer to a menu
                var waited = 0
                while !Task.isCancelled, callerActivity?() == true, waited < 8 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    waited += 1
                }
                guard !Task.isCancelled, let self else { return }
                // From here on the model is working: new speech must not cancel this task
                // (that would abort the request: "cancelled")
                await self.detachMenuFlushTask()
                do {
                    if let response = try await self.flushPendingMenu(), !response.isEmpty {
                        onResponse(response)
                    }
                } catch {
                    onResponse("Agent error: \(error.localizedDescription)")
                }
            }
            return nil
        }
        return try await injectCallerSpeech(text, language: language)
    }

    /// Tools that act in the call or wait for the user: after them, wait for the next event
    static let turnEndingTools: Set<String> = ["send_dtmf", "say_to_caller", "end_call", "ask_user", "dial_number", "accept_call"]

    /// Keys are only typed when they're a menu choice or a number the user gave
    private func dtmfRefusal(_ input: [String: Any], alreadySent: Bool) -> String? {
        let raw = (input["digits"] ?? input["digit"]).map { "\($0)" } ?? ""
        let digits = Self.digitsOnly(raw)
        if alreadySent {
            return "Refused: one entry at a time. Wait for the voice server's answer."
        }
        // One or two keys = a menu choice. Longer = an identifier: it must come from the user.
        if digits.count > 2 && !knownDigits.contains(digits) {
            return "Refused: never make up a number. Ask for it with ask_user (or answer WAIT)."
        }
        return nil
    }

    static func digitsOnly(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber })
    }

    private func detachMenuFlushTask() {
        menuFlushTask = nil
    }

    private func takePendingMenu() -> String? {
        menuFlushTask?.cancel()
        menuFlushTask = nil
        guard !pendingMenu.isEmpty else { return nil }
        defer { pendingMenu.removeAll() }
        return pendingMenu.joined(separator: " ")
    }

    private func flushPendingMenu() async throws -> String? {
        guard outgoingCall != nil, let menu = takePendingMenu() else { return nil }
        menuWantsSpeech = Self.asksToSpeak(menu)
        logger.info("Complete menu: \(menu.prefix(80))")
        return try await injectCallerSpeech(menu, language: pendingMenuLanguage, completeMenu: true)
    }

    /// Add context without asking the model to respond (e.g. the user spoke or pressed keys directly)
    public func addNote(_ note: String) {
        conversationHistory.append(ChatMessage(role: "user", content: "[NOTE] \(note)"))
    }

    /// Forget the conversation (new mission)
    public func reset() {
        conversationHistory.removeAll()
    }

    /// Start listening for HFP events and forwarding them to the agent
    public nonisolated func startEventListener(onResponse: @escaping @Sendable (String) -> Void) -> Task<Void, Never> {
        let stream = eventStream.makeStream()

        return Task { [weak self] in
            for await event in stream {
                guard let self = self else { break }

                do {
                    let response: String?
                    switch event {
                    case .callDialing:
                        await self.setOutgoingCall(true)
                        response = nil
                    case .incomingCall(let number):
                        await self.setOutgoingCall(false)
                        response = try await self.handleIncomingCall(number: number)
                    case .callEnded:
                        response = try await self.injectEvent("The call has ended (don't use end_call, it's already hung up) — give the user a short summary")
                        await self.setOutgoingCall(nil)
                    case .callActive:
                        // Audio isn't connected yet: the agent can't be heard, so don't
                        // make it speak now (it would greet again on scoConnected)
                        await self.addNote("The call is now active — wait for the audio to be connected")
                        response = nil
                    case .scoConnected:
                        if await self.outgoingCall == true {
                            // Outgoing: listen first (often an IVR), speak only once someone talks
                            await self.addNote("Audio connected — listen: a voice server or a human is about to speak")
                            response = nil
                        } else {
                            response = try await self.injectEvent("Audio connected — you can now hear and talk to the caller\(await self.directionHint)")
                        }
                    case .scoDisconnected:
                        response = try await self.injectEvent("Audio disconnected")
                    case .callerSpeech(let text, let language):
                        response = try await self.receiveCallerSpeech(text, language: language, onResponse: onResponse)
                    default:
                        response = nil
                    }
                    if let response, !response.isEmpty {
                        onResponse(response)
                    }
                } catch {
                    self.logger.error("Failed to process event: \(error)")
                    onResponse("Agent error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Private

    private func setOutgoingCall(_ value: Bool?) {
        outgoingCall = value
        heardCaller = false
        ivrMode = false
        humanConfirmed = false
        menuWantsSpeech = false
        _ = takePendingMenu()
        pendingMenuLanguage = nil
    }

    /// Voice server phrases: greetings, recordings, menus
    static func looksLikeIVR(_ text: String) -> Bool {
        if looksLikeMenu(text) { return true }
        let t = text.lowercased()
        return ["thank you for calling", "thanks for calling", "your call is important",
                "this call may be recorded", "please hold", "please wait", "for english",
                "merci d'avoir appelé", "merci de votre appel", "votre appel est important",
                "cet appel est enregistré", "veuillez patienter", "temps d'attente",
                "תודה שהתקשרת", "שהתקשרתם", "נשמח לעמוד לשירות", "השיחה מוקלטת", "שיחתך חשובה",
                "הנך מועבר", "אנא המתן", "אנא המתינו", "זמן ההמתנה", "לשירותכם", "מוקלטת", "המתינו"]
            .contains { t.contains($0) }
    }

    /// Speech-recognition menus: "say in a few words the reason for your call"
    static func asksToSpeak(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["say ", "tell us", "in a few words",
                "dites", "décrivez", "en quelques mots",
                "אמרו", "אמור ", "אמרי", "תארו", "במילים", "בקצרה את"]
            .contains { t.contains($0) }
    }

    /// A person (not a recording) picked up: "Dana speaking, how can I help?"
    static func looksLikeHuman(_ text: String) -> Bool {
        let t = text.lowercased()
        // "Hello?", "Oui, allo, bonjour", "Allô ?", "הלו" — any form of hello-on-the-phone
        if t.range(of: #"(^|[^\p{L}])(hello|all[oô]|hall[oô]|הלו)([^\p{L}]|$)"#, options: .regularExpression) != nil {
            return true
        }
        return ["speaking", "my name is", "how can i help", "how may i help", "hello?", "hello ?",
                "je m'appelle", "à l'appareil", "que puis-je faire pour vous", "comment puis-je vous aider",
                "allô", "allo ?", "allo?",
                "מדבר", "מדברת", "שמי ", "במה אוכל לעזור", "איך אפשר לעזור", "איך אוכל לעזור", "הלו"]
            .contains { t.contains($0) }
    }

    /// Words IVR menus use to list options ("press 1 for…")
    static func looksLikeMenu(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["press", "dial ",
                "tapez", "appuyez", "touche", "faites le",
                "הקש", "הקישו", "לחץ", "לחצו", "שלוחה", "שלוחת", "בחר"]
            .contains { t.contains($0) }
    }

    /// Reminds the model who placed the call, so it doesn't greet a callee like a caller
    private var directionHint: String {
        switch outgoingCall {
        case true?:
            return " (OUTGOING call: you are the one calling — listen first; voice server → send_dtmf; human → introduce yourself and state the reason for your call, without asking them what the call is about)"
        case false?:
            return " (INCOMING call: the caller called you)"
        case nil:
            return ""
        }
    }

    private func handleIncomingCall(number: String?) async throws -> String {
        let caller = number ?? "unknown number"
        guard autoAnswer else {
            return try await injectEvent("Incoming call from \(caller)")
        }
        let result = toolExecutor.execute(toolName: "accept_call", input: [:])
        return try await injectEvent("Incoming call from \(caller) — answered automatically (\(result))")
    }

    private func runAgentLoop(speakFallback: Bool) async throws -> String {
        trimHistory()

        var spoke = false
        let maxIterations = 6

        for _ in 0..<maxIterations {
            let messages = [ChatMessage(role: "system", content: systemPrompt)] + conversationHistory
            let response = try await client.chat(messages: messages, tools: PhoneTools.allTools)
            conversationHistory.append(response)

            guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                // No tool call — final text answer
                if Self.isWaitMarker(response.content) {
                    return ""
                }
                if speakFallback && !spoke {
                    logger.info("Model replied without say_to_caller — speaking text anyway")
                    _ = toolExecutor.execute(toolName: "say_to_caller", input: ["text": response.content])
                }
                return response.content
            }

            var spokenTexts: [String] = []
            var acted = false
            var keysSent = false
            for call in toolCalls {
                let name = call.function.name
                let input = call.function.arguments.mapValues(\.anyValue)
                logger.info("Tool call: \(name)")
                let result: String
                if name == "say_to_caller" && outgoingCall == true && !heardCaller {
                    // Outgoing call: never speak first (it's usually an IVR)
                    logger.info("say_to_caller blocked: nobody has spoken yet")
                    result = #"{"error":"Refused: nobody has spoken yet. Listen first; if it's a voice server, use send_dtmf. Answer WAIT.","success":false}"#
                } else if name == "dial_number" && toolExecutor.isInCall {
                    // Small models sometimes "dial" a number heard in a voice menu mid-call
                    logger.info("dial_number blocked: a call is in progress")
                    result = #"{"error":"Refused: a call is already in progress. For a voice menu, use send_dtmf; otherwise answer WAIT.","success":false}"#
                } else if name == "send_dtmf", let refusal = dtmfRefusal(input, alreadySent: keysSent) {
                    logger.info("send_dtmf blocked: \(refusal)")
                    result = #"{"error":"\#(refusal)","success":false}"#
                } else if name == "say_to_caller" && ivrMode && !menuWantsSpeech {
                    // A voice menu doesn't understand speech: keys only, until a human answers
                    logger.info("say_to_caller blocked: IVR")
                    result = #"{"error":"Refused: this is a voice server, it doesn't understand speech. Use send_dtmf, or ask_user if you don't know which key to choose, or answer WAIT.","success":false}"#
                } else {
                    result = toolExecutor.execute(toolName: name, input: input)
                }
                conversationHistory.append(ChatMessage(role: "tool", content: result, toolName: name))
                if result.contains(#""success":true"#) {
                    if name == "send_dtmf" { keysSent = true }
                    if Self.turnEndingTools.contains(name) { acted = true }
                }

                if name == "say_to_caller", result.contains(#""success":true"#), let text = input["text"] as? String {
                    spoke = true
                    spokenTexts.append(text)
                }
            }

            // If the model only spoke to the caller, the turn is done: skip an extra
            // LLM round-trip to keep conversation latency low.
            if spokenTexts.count == toolCalls.count {
                return spokenTexts.map { "🗣️  \($0)" }.joined(separator: "\n")
            }
            // An action in the call (keys, speech, hang-up, question) ends the turn: the next
            // step depends on what the other party does. Looping here made the model send
            // key after key without listening.
            if acted {
                return spokenTexts.map { "🗣️  \($0)" }.joined(separator: "\n")
            }
        }

        logger.error("Agent loop hit the iteration limit")
        return ""
    }

    /// The model chose to stay silent (IVR still talking, hold music…)
    static func isWaitMarker(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased()
        return t.isEmpty || t == "WAIT" || t == "ATTENTE"
    }

    /// Keep the context small: drop the oldest messages, never starting on a tool result
    private func trimHistory() {
        guard conversationHistory.count > maxHistoryMessages else { return }
        conversationHistory.removeFirst(conversationHistory.count - maxHistoryMessages)
        while let first = conversationHistory.first, first.role != "user" {
            conversationHistory.removeFirst()
        }
    }
}
