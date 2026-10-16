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
    private var knownNumbers: Set<String>
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
    /// When keys were last pressed: speech transcribed just after was spoken before the press
    /// (Whisper lags ~1–2 s) and belongs to the previous menu
    private var lastKeyPress: Date?
    private let keyPressEcho: TimeInterval = 3
    /// The user's instructions for the current mission (restated to the model with each turn:
    /// small models forget them after a few menu steps)
    private var missionNotes: [String] = []
    /// The current call was answered (summaries only make sense then)
    private var callConnected = false
    /// Last thing the caller said (to check what a menu asked for)
    private var lastCallerText = ""
    /// Is the other party talking (or being transcribed) right now?
    private let callerActivity: (@Sendable () -> Bool)?
    private let systemPrompt: String
    private let maxHistoryMessages = 40

    public static let baseSystemPrompt = """
        You are a phone assistant acting ON BEHALF of the user (the person you work for, who \
        follows the call from their computer). You place and receive calls with their phone. \
        The "caller" is whoever is on the line (a person or a voice server) — never the user.

        # 1. The user's instructions come first
        - Do exactly what the user asks, right away, even in the middle of a call: press the key \
        they name, say what they want said, hang up when they say so. Their instructions \
        override your own judgment and any previous plan.
        - Remember the mission for the whole call. Each caller message ends with [MISSION]: the \
        user's instructions so far. Every action must serve it.

        # 2. Messages you receive
        - No prefix: an instruction or answer from the user.
        - [CALLER SPEECH lang=xx call=outgoing|incoming] "...": what the caller said (detected \
        language xx). Transcriptions contain errors: rely on the meaning, not the exact words. \
        (MENU) / (FULL MENU) = a voice server reading options.
        - [PHONE EVENT]: call events. [NOTE]: context, no answer needed.

        # 3. Voice servers (automated menus)
        - Never talk to a voice server (it doesn't understand speech) unless it asks you to say \
        something. Use send_dtmf.
        - Press ONE key per menu, then wait for what comes next. Never press a key for an option \
        the user didn't ask for.
        - Language choice ("for English press 2", "pour le français tapez 4"): press the key for \
        {USER_LANGUAGE}, else English, unless the user asked otherwise.
        - Other menus: press the option that matches the mission. If none clearly matches, or \
        there is no mission yet: ask_user, listing ONLY the options you actually heard ("key — \
        option", translated into {USER_LANGUAGE}), and wait.
        - Asked for a number (ID, customer number, date of birth…): type it with send_dtmf (+ # if \
        asked) only if THAT exact kind of number is in the user's info or messages (an ID number \
        is not a customer number); otherwise ask_user. Never make up digits.
        - Information, hold music, "please wait", incomplete menu: answer WAIT (the single word, \
        no tool).

        # 4. Talking with a person
        - Speak only with say_to_caller: it is the only way the caller hears you. One or two \
        short, natural spoken sentences; no emoji, markdown or lists.
        - Answer in the caller's language (lang field) and pass it as the language parameter.
        - Outgoing call: LISTEN FIRST, never speak first. When a person answers ("hello", "allô", \
        "this is Dana, how can I help?"), introduce yourself once and state the reason for the \
        call directly, e.g. "Hello, I'm calling on behalf of <user's name> about…". Never ask \
        them what the call is about.
        - Missing information or a decision: ask_user, then ask the person to hold on.
        - Share the user's personal data only when needed for the mission and asked for.
        - Mission done or the caller says goodbye: say goodbye, then end_call.

        # 5. Reporting to the user
        - Speak {USER_LANGUAGE} with the user (also in ask_user). Be brief and factual.
        - After a call, report only what you actually heard and did. Say clearly what was NOT \
        confirmed. Never claim a success the caller didn't confirm.
        - For a call you placed, there is nothing to pick up: "call active" means they answered. \
        Your answers to the user never start with a bracketed prefix.
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
        self.knownNumbers = Self.numbers(in: userProfile ?? "")
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
        knownNumbers.formUnion(Self.numbers(in: userMessage))
        missionNotes.append(userMessage)
        if missionNotes.count > 6 { missionNotes.removeFirst() }

        // "appuie sur 1", "press 3": do it now, the model sometimes didn't
        if outgoingCall != nil || toolExecutor.isInCall, let keys = Self.directKeyCommand(userMessage) {
            let result = toolExecutor.execute(toolName: "send_dtmf", input: ["digits": keys])
            if result.contains(#""success":true"#) { keysPressed() }
            conversationHistory.append(ChatMessage(role: "user", content: userMessage))
            conversationHistory.append(ChatMessage(role: "assistant", content: "", toolCalls: [
                ToolCall(function: .init(name: "send_dtmf", arguments: ["digits": .string(keys)]))
            ]))
            conversationHistory.append(ChatMessage(role: "tool", content: result, toolName: "send_dtmf"))
            logger.info("Direct key command: \(keys)")
            return ""
        }
        conversationHistory.append(ChatMessage(role: "user", content: userMessage))
        return try await runAgentLoop(speakFallback: false)
    }

    /// A message that only asks to press keys ("appuie sur 1", "tape 4", "press 2#")
    static func directKeyCommand(_ text: String) -> String? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "*#"))))
        let pattern = #"^(appuie|appuies|appuis|appuyer|appuyez|tape|tapes|taper|tapez|presse|press|hit|dial|touche)( sur| on)?( la touche| the key| key| touche)?\s*([0-9*#][0-9*# ]*)$"#
        guard let match = t.range(of: pattern, options: .regularExpression) else { return nil }
        let keys = String(t[match]).filter { $0.isNumber || $0 == "*" || $0 == "#" }
        return keys.isEmpty || keys.count > 3 ? nil : keys
    }

    /// Keys were just pressed (by the agent or the user): the menu being read is over
    func keysPressed() {
        lastKeyPress = Date()
        _ = takePendingMenu()
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
        lastCallerText = text
        var attributes = language.map { " lang=\($0)" } ?? ""
        if let outgoingCall { attributes += outgoingCall ? " call=outgoing" : " call=incoming" }
        let tag = "[CALLER SPEECH\(attributes)]"
        let menu: String
        if completeMenu {
            menu = " (FULL MENU) — voice server. Decide in this order: 1) no key is offered (information, opening hours, hold message) → WAIT. 2) language choice → the key for {USER_LANGUAGE}, else English. 3) it asks for a number → type it if it is in the user's info, else ask_user. 4) one option clearly matches the [MISSION] → press that single key. 5) otherwise (the mission doesn't say which option, e.g. just \"call X\") → ask_user listing ONLY the options heard, as 'key — option'."
        } else if ivrMode || Self.looksLikeMenu(text) {
            menu = " (MENU, incomplete — more options may follow) — press a key ONLY if the option matching the [MISSION] (or {USER_LANGUAGE} in a language choice) was just read; otherwise WAIT."
        } else {
            menu = ""
        }
        let hint = menu.replacingOccurrences(of: "{USER_LANGUAGE}", with: UILanguage.agent.englishName)
        conversationHistory.append(ChatMessage(role: "user", content: "\(tag) \"\(text)\"\(hint)\(missionReminder)"))
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
        if ivrMode, let lastKeyPress, Date().timeIntervalSince(lastKeyPress) < keyPressEcho {
            logger.info("Ignoring menu speech heard right after a key press: \(text.prefix(60))")
            return nil
        }
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

    /// The user's instructions, restated with each caller message
    private var missionReminder: String {
        guard !missionNotes.isEmpty else { return "\n[MISSION] none given yet — if a choice is needed, ask_user" }
        let asked = "\n[MISSION] the user asked: " + missionNotes.map { "\"\($0)\"" }.joined(separator: " then ")
        if missionNotes.allSatisfy(Self.isDialOnly) {
            return asked + " — only to call, with no goal: for any menu choice or question, ask_user (don't guess)"
        }
        return asked
    }

    /// "Appelle le 3900", "call *166": a number to call, without saying what for
    static func isDialOnly(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "*#+"))))
        return t.range(of: #"^(appelle|appeler|rappelle|compose|call|dial|phone)( le| la| au| the)?\s*[0-9*#+][0-9*#+ .-]*$"#, options: .regularExpression) != nil
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
        if digits.count > 2 && !knownNumbers.contains(digits) {
            return "Refused: never make up a number. Ask for it with ask_user (or answer WAIT)."
        }
        return nil
    }

    /// The number as the user typed it: models drop the * or # of service codes ("*0555" → "0555")
    private func numberAsTyped(_ number: String) -> String {
        let digits = Self.digitsOnly(number)
        guard !digits.isEmpty else { return number }
        for note in missionNotes.reversed() {
            for token in note.split(whereSeparator: { $0 == " " || $0 == "," }) {
                let candidate = token.filter { $0.isNumber || $0 == "*" || $0 == "#" || $0 == "+" }
                if Self.digitsOnly(candidate) == digits, candidate != number { return String(candidate) }
            }
            // "appelle le*0555": the number glued to a word
            if let range = note.range(of: #"[*#+]?\d[\d *#-]*"#, options: .regularExpression) {
                let candidate = note[range].filter { $0.isNumber || $0 == "*" || $0 == "#" || $0 == "+" }
                if Self.digitsOnly(candidate) == digits { return String(candidate) }
            }
        }
        return number
    }

    /// Every number written in a text ("123 456 789", "06-12-34-56-78" count as one), digits only
    static func numbers(in text: String) -> Set<String> {
        var found = Set<String>()
        var rest = text[...]
        while let range = rest.range(of: #"\d[\d .\-/]*\d|\d"#, options: .regularExpression) {
            found.insert(digitsOnly(String(rest[range])))
            rest = rest[range.upperBound...]
        }
        return found
    }

    /// A menu choice doesn't take "#" unless the menu asked for it ("4#" → "4")
    static func menuKeys(_ digits: String, heard: String) -> String {
        guard digits.count == 2, digits.hasSuffix("#"), digits.first?.isNumber == true else { return digits }
        let asksForHash = heard.range(of: #"#|dièse|diese|hash|pound|סולמית|carré"#, options: [.regularExpression, .caseInsensitive]) != nil
        return asksForHash ? digits : String(digits.dropLast())
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
        // Information or hold message: nothing to press or say, don't ask the model
        // (it tended to press a key or ask the user anyway)
        if !Self.looksLikeMenu(menu) && !menuWantsSpeech {
            logger.info("Voice server message without choices: \(menu.prefix(80))")
            conversationHistory.append(ChatMessage(role: "user", content: "[NOTE] The voice server said (no choice offered, nothing to do): \"\(menu)\""))
            return nil
        }
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
                        if await self.callConnected {
                            response = try await self.injectEvent("The call has ended (don't use end_call, it's already hung up) — give the user a short summary: only what you actually heard and did; say clearly what was NOT confirmed")
                        } else {
                            await self.addNote("The call ended before anyone answered")
                            response = nil
                        }
                        await self.setOutgoingCall(nil)
                        await self.clearMission()
                    case .callActive:
                        await self.markConnected()
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

    private func markConnected() { callConnected = true }

    private func clearMission() { missionNotes.removeAll() }

    private func setOutgoingCall(_ value: Bool?) {
        outgoingCall = value
        callConnected = false
        lastKeyPress = nil
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
        return ["press", "dial ", "enter your", "type your", "key in",
                "tapez", "appuyez", "touche", "faites le", "saisi", "entrez", "composez",
                "הקש", "הקישו", "לחץ", "לחצו", "שלוחה", "שלוחת", "בחר", "הזינו", "הקלידו"]
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
                if name == "say_to_caller" && outgoingCall == nil && !toolExecutor.isInCall {
                    // Nobody on the line: the text is meant for the user
                    logger.info("say_to_caller without a call: replying to the user")
                    let text = (input["text"] as? String) ?? ""
                    conversationHistory.append(ChatMessage(role: "tool", content: #"{"error":"No call in progress: shown to the user instead.","success":false}"#, toolName: name))
                    return text
                } else if name == "say_to_caller" && outgoingCall == true && !heardCaller {
                    // Outgoing call: never speak first (it's usually an IVR)
                    logger.info("say_to_caller blocked: nobody has spoken yet")
                    result = #"{"error":"Refused: nobody has spoken yet. Listen first; if it's a voice server, use send_dtmf. Answer WAIT.","success":false}"#
                } else if name == "dial_number" && toolExecutor.isInCall {
                    // Small models sometimes "dial" a number heard in a voice menu mid-call
                    logger.info("dial_number blocked: a call is in progress")
                    result = #"{"error":"Refused: a call is already in progress. For a voice menu, use send_dtmf; otherwise answer WAIT.","success":false}"#
                } else if name == "send_dtmf" && outgoingCall == nil && !toolExecutor.isInCall,
                          let raw = (input["digits"] ?? input["digit"]).map({ "\($0)" }) {
                    // No call yet: "call *2994" sometimes comes out as keys. Dial the number instead.
                    let number = numberAsTyped(raw.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
                    if missionNotes.contains(where: { Self.numbers(in: $0).contains(Self.digitsOnly(number)) }) {
                        logger.info("send_dtmf without a call: dialing \(number)")
                        result = toolExecutor.execute(toolName: "dial_number", input: ["number": number])
                    } else {
                        result = #"{"error":"Refused: no call in progress, keys can't be sent. To place a call, use dial_number with the number the user gave.","success":false}"#
                    }
                } else if name == "send_dtmf", let refusal = dtmfRefusal(input, alreadySent: keysSent) {
                    logger.info("send_dtmf blocked: \(refusal)")
                    result = #"{"error":"\#(refusal)","success":false}"#
                } else if name == "say_to_caller" && ivrMode && !menuWantsSpeech {
                    // A voice menu doesn't understand speech: keys only, until a human answers
                    logger.info("say_to_caller blocked: IVR")
                    result = #"{"error":"Refused: this is a voice server, it doesn't understand speech. Use send_dtmf, or ask_user if you don't know which key to choose, or answer WAIT.","success":false}"#
                } else if name == "send_dtmf", let raw = (input["digits"] ?? input["digit"]).map({ "\($0)" }),
                          case let keys = Self.menuKeys(raw.replacingOccurrences(of: " ", with: ""), heard: lastCallerText), keys != raw {
                    logger.info("send_dtmf: \(raw) → \(keys)")
                    result = toolExecutor.execute(toolName: name, input: ["digits": keys])
                } else if name == "dial_number" {
                    var fixed = input
                    if let number = input["number"] as? String { fixed["number"] = numberAsTyped(number) }
                    result = toolExecutor.execute(toolName: name, input: fixed)
                } else {
                    result = toolExecutor.execute(toolName: name, input: input)
                }
                if name == "send_dtmf", result.contains(#""success":true"#) { keysPressed() }
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
