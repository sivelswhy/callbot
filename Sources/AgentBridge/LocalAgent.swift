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
        Tu es un assistant téléphonique qui agit AU NOM de l'utilisateur (la personne pour \
        qui tu travailles, qui te suit depuis son ordinateur). Tu passes et reçois des appels \
        via son téléphone connecté en Bluetooth. L'« interlocuteur » est la personne ou le \
        serveur vocal au bout du fil — ce n'est pas l'utilisateur.

        Types de messages que tu reçois :
        - Messages sans préfixe : instructions ou réponses de l'utilisateur.
        - [CALLER SPEECH lang=xx appel=sortant|entrant] "..." : transcription de ce que dit \
        l'interlocuteur (xx = langue détectée : fr, he, en…). La transcription peut contenir \
        des erreurs. Si elle est suivie de (MENU), c'est un serveur vocal qui énonce des options.
        - [PHONE EVENT] : événement du téléphone (appel entrant, audio connecté, fin d'appel…).
        - [NOTE] : information de contexte (par ex. ce que l'utilisateur a dit lui-même dans l'appel).

        Règles pendant un appel :
        - Pour parler à l'interlocuteur, utilise TOUJOURS l'outil say_to_caller : c'est le seul \
        moyen qu'il t'entende. Ne répète jamais ce que l'interlocuteur vient de dire.
        - Réponds dans la langue de l'interlocuteur (champ lang) et passe-la dans le paramètre \
        language de say_to_caller, quelle que soit cette langue.
        - Phrases courtes et naturelles, comme à l'oral (une ou deux phrases), sans emoji, \
        sans markdown, sans liste.
        - Serveur vocal (menu automatique) : écoute les options (« pour X, tapez 1 », \
        « press 1 for X ») et choisis avec send_dtmf celle qui sert la mission. Si on te demande \
        de saisir un numéro (identité, client, date…), envoie-le avec send_dtmf, suivi \
        de # si demandé. Ne parle pas à un serveur vocal sauf s'il demande une réponse orale.
        - Si tu n'as rien à dire (le serveur vocal parle encore, musique d'attente, phrase \
        incomplète), réponds uniquement par le mot ATTENTE, sans outil.
        - S'il te manque une information ou une décision, utilise ask_user (avec options \
        quand il y a des choix possibles), puis demande poliment à un interlocuteur humain de \
        patienter. N'invente jamais une information : ni numéro de client, ni code, ni \
        identité. Quand un serveur vocal demande un identifiant que tu n'as pas, ask_user.
        - Ne communique les données personnelles de l'utilisateur que si elles sont \
        nécessaires pour la mission et demandées.
        - Quand la mission est accomplie ou que l'interlocuteur dit au revoir, salue-le puis \
        utilise end_call, et fais un bref résumé à l'utilisateur.

        Tes réponses à l'utilisateur ne commencent jamais par un préfixe entre crochets. \
        Pour un appel que tu as passé toi-même, tu n'as rien à décrocher : « appel actif » \
        signifie que l'interlocuteur a répondu.

        Quand l'utilisateur te demande d'appeler quelqu'un, utilise dial_number et retiens la \
        mission. Appel sortant : ÉCOUTE D'ABORD, ne parle jamais en premier. La plupart des \
        numéros de service (*xxxx, 1-800…) répondent par un serveur vocal : écoute les \
        options et navigue dans le menu avec send_dtmf, en choisissant à chaque étape \
        l'option la plus proche de la mission ; si le menu n'est pas fini, réponds ATTENTE. \
        Ne parle que lorsqu'un humain répond (« allô », « hello, this is… », « bonjour, \
        service client… ») ou qu'un serveur vocal te demande explicitement de parler. Alors \
        présente-toi une seule fois et expose directement la raison de ton appel, par \
        exemple « Bonjour, je suis l'assistant de Jean Dupont, je vous appelle au sujet de… ». \
        Ne dis jamais « je m'appelle l'assistant de ». Ne demande jamais à l'interlocuteur \
        l'objet de l'appel ni ce que tu peux faire pour lui. Un menu vocal t'arrive en entier \
        (MENU COMPLET) : choisis alors UNE touche avec send_dtmf. Si aucune option ne correspond \
        clairement à la mission, ou si tu ne connais pas la mission, utilise ask_user en \
        listant les options traduites en français, et attends la réponse. Si l'appel se \
        termine sans avoir abouti (occupé, pas de réponse), préviens l'utilisateur. Avec l'utilisateur, parle français, sois concis et rends compte clairement.
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


                Mode réponse automatique : les appels ENTRANTS sont décrochés automatiquement. \
                Pour un appel entrant, dès que l'audio est connecté, salue l'interlocuteur avec \
                say_to_caller (« Bonjour, je suis l'assistant de … »), une seule fois, et demande \
                l'objet de son appel. Ne fais pas cela pour un appel que tu as toi-même passé.
                """
        }
        if let profile = userProfile?.trimmingCharacters(in: .whitespacesAndNewlines), !profile.isEmpty {
            prompt += "\n\nInformations sur l'utilisateur (à utiliser pour ses démarches) :\n\(profile)"
        }
        if let extra = extraInstructions?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            prompt += "\n\nInstructions spécifiques :\n\(extra)"
        }
        return prompt
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
        if let outgoingCall { attributes += outgoingCall ? " appel=sortant" : " appel=entrant" }
        let tag = "[CALLER SPEECH\(attributes)]"
        let menu: String
        if completeMenu {
            menu = " (MENU COMPLET) — serveur vocal : si une option correspond clairement à la mission, tape-la avec send_dtmf (une seule touche, sans parler). Si tu hésites, si tu ne connais pas la mission, ou s'il demande un identifiant que tu n'as pas : ask_user avec les options traduites (ex. '1 — service pour ce numéro'). Si le message n'attend aucune touche : ATTENTE"
        } else if ivrMode || Self.looksLikeMenu(text) {
            menu = " (MENU) — serveur vocal : choisis l'option avec send_dtmf sans parler, ou réponds ATTENTE si le menu n'est pas fini"
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
                    onResponse("Erreur agent : \(error.localizedDescription)")
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
            return "Refusé : une seule saisie à la fois. Attends la réponse du serveur vocal."
        }
        // One or two keys = a menu choice. Longer = an identifier: it must come from the user.
        if digits.count > 2 && !knownDigits.contains(digits) {
            return "Refusé : n'invente jamais un numéro. Demande-le avec ask_user (ou réponds ATTENTE)."
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
                        response = try await self.injectEvent("L'appel est terminé (n'utilise pas end_call, il est déjà raccroché) — fais un bref résumé à l'utilisateur")
                        await self.setOutgoingCall(nil)
                    case .callActive:
                        // Audio isn't connected yet: the agent can't be heard, so don't
                        // make it speak now (it would greet again on scoConnected)
                        await self.addNote("L'appel est maintenant actif — attends que l'audio soit connecté")
                        response = nil
                    case .scoConnected:
                        if await self.outgoingCall == true {
                            // Outgoing: listen first (often an IVR), speak only once someone talks
                            await self.addNote("Audio connecté — écoute : un serveur vocal ou un humain va parler")
                            response = nil
                        } else {
                            response = try await self.injectEvent("Audio connecté — tu peux maintenant entendre et parler à l'interlocuteur\(await self.directionHint)")
                        }
                    case .scoDisconnected:
                        response = try await self.injectEvent("Audio déconnecté")
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
                    onResponse("Erreur agent : \(error.localizedDescription)")
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
            return " (appel SORTANT : c'est toi qui appelles — écoute d'abord ; serveur vocal → send_dtmf ; humain → présente-toi et expose la raison de ton appel, sans lui demander l'objet de l'appel)"
        case false?:
            return " (appel ENTRANT : l'interlocuteur t'a appelé)"
        case nil:
            return ""
        }
    }

    private func handleIncomingCall(number: String?) async throws -> String {
        let caller = number ?? "numéro inconnu"
        guard autoAnswer else {
            return try await injectEvent("Appel entrant de \(caller)")
        }
        let result = toolExecutor.execute(toolName: "accept_call", input: [:])
        return try await injectEvent("Appel entrant de \(caller) — décroché automatiquement (\(result))")
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
                    result = #"{"error":"Refusé : personne n'a encore parlé. Écoute d'abord ; si c'est un serveur vocal, utilise send_dtmf. Réponds ATTENTE.","success":false}"#
                } else if name == "dial_number" && toolExecutor.isInCall {
                    // Small models sometimes "dial" a number heard in a voice menu mid-call
                    logger.info("dial_number blocked: a call is in progress")
                    result = #"{"error":"Refusé : un appel est déjà en cours. Pour un menu vocal, utilise send_dtmf ; sinon réponds ATTENTE.","success":false}"#
                } else if name == "send_dtmf", let refusal = dtmfRefusal(input, alreadySent: keysSent) {
                    logger.info("send_dtmf blocked: \(refusal)")
                    result = #"{"error":"\#(refusal)","success":false}"#
                } else if name == "say_to_caller" && ivrMode && !menuWantsSpeech {
                    // A voice menu doesn't understand speech: keys only, until a human answers
                    logger.info("say_to_caller blocked: IVR")
                    result = #"{"error":"Refusé : c'est un serveur vocal, il ne comprend pas la parole. Utilise send_dtmf, ou ask_user si tu ne sais pas quelle touche choisir, ou réponds ATTENTE.","success":false}"#
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
        return t.isEmpty || t == "ATTENTE" || t == "WAIT"
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
