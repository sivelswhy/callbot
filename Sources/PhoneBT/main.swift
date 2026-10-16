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
import AgentBridge
import Shared

// MARK: - CLI Application

func printBanner() {
    print("""

    ╔══════════════════════════════════════╗
    ║          PhoneBT v0.2.0             ║
    ║  Bluetooth HFP Client for macOS    ║
    ║  Local AI phone agent (offline)    ║
    ╚══════════════════════════════════════╝
    """)
}

func printHelp() {
    print(L("""
    Commands:
      scan             - Search for Bluetooth devices
      paired           - List paired devices
      connect <idx>    - Connect to device number idx
      disconnect       - Disconnect
      dial <number>    - Call a number
      answer / hangup  - Answer / hang up
      keys <keys>      - Press keys (e.g. keys 123456789#)
      say <text>       - Say a text in the call (TTS)
      status / phone   - Call / phone status
      check            - Check the local AI stack
      voices           - Installed voices
      profile          - Show the path of your profile file
      agent [auto]     - AI agent mode (auto = answers calls by itself)
      help / quit

    In agent mode: free text = instruction or answer to the agent,
      > text = said directly in the call, # 123 = keys, exit = quit.
    Languages: PHONEBT_UI_LANG=en|fr (app), PHONEBT_AGENT_LANG=en|fr (agent).
    """, """
    Commandes :
      scan             - Chercher des appareils Bluetooth
      paired           - Lister les appareils appairés
      connect <idx>    - Se connecter à l'appareil n°idx
      disconnect       - Se déconnecter
      dial <numéro>    - Appeler un numéro
      answer / hangup  - Décrocher / raccrocher
      keys <touches>   - Taper des touches (ex : keys 123456789#)
      say <texte>      - Dire un texte dans l'appel (TTS)
      status / phone   - État de l'appel / du téléphone
      check            - Vérifier la pile IA locale
      voices           - Voix installées
      profile          - Afficher le chemin de ton dossier perso
      agent [auto]     - Mode agent IA (auto = décroche tout seul)
      help / quit

    En mode agent : texte libre = instruction ou réponse à l'agent,
      > texte = dit directement dans l'appel, # 123 = touches, exit = quitter.
    Langues : PHONEBT_UI_LANG=en|fr (app), PHONEBT_AGENT_LANG=en|fr (agent).
    """))
}

let session = PhoneSession()
var devices: [DiscoveredDevice] = []

session.onLog = { entry in
    let prefix: String
    switch entry.kind {
    case .system: prefix = "ℹ️ "
    case .error: prefix = "⚠️ "
    case .caller(let lang): prefix = L("🗣️  Caller [\(lang ?? "?")]:", "🗣️  Interlocuteur [\(lang ?? "?")] :")
    case .agent: prefix = L("🤖 Agent:", "🤖 Agent :")
    case .agentSpoke: prefix = L("🤖🔊 Agent says:", "🤖🔊 Agent dit :")
    case .question: prefix = L("❓ The agent asks you:", "❓ L'agent te demande :")
    case .user: return
    case .userSpoke: prefix = L("🔊 You say:", "🔊 Tu dis :")
    case .keys: prefix = L("🔢 Keys:", "🔢 Touches :")
    case .translation: prefix = "   ↳ (\(UILanguage.agent.rawValue.uppercased()))"
    }
    print("\n\(prefix) \(entry.text)")
    fflush(stdout)
}

signal(SIGINT) { _ in
    print(L("\nStopping...", "\nArrêt..."))
    session.shutdown()
    exit(0)
}

func printDevices() {
    if devices.isEmpty {
        print(L("No device found.", "Aucun appareil trouvé."))
        return
    }
    for (i, d) in devices.enumerated() {
        print("  [\(i)] \(d.name) (\(d.address))\(d.isHandsFreeGateway ? " [HFP]" : "")")
    }
}

func handleStatus() {
    guard let state = session.state else {
        print(L("Not connected.", "Non connecté."))
        return
    }
    print(L("Connection: \(state.connection.rawValue) · Call: \(state.call.rawValue) · Audio: \(state.audio.rawValue)", "Connexion : \(state.connection.rawValue) · Appel : \(state.call.rawValue) · Audio : \(state.audio.rawValue)"))
    if let call = state.activeCall {
        print("  \(call.direction.rawValue) \(call.number ?? L("unknown", "inconnu")) \(call.durationDescription ?? "")")
    }
}

func handlePhone() {
    guard let phone = session.state?.phoneStatus else {
        print(L("Not connected.", "Non connecté."))
        return
    }
    print(L("Signal", "Réseau") + " \(phone.signalStrength)/5 · " + L("Battery", "Batterie") + " \(phone.batteryLevel)/5 · " + (phone.operatorName ?? L("unknown carrier", "opérateur inconnu")) + (phone.roaming ? L(" · roaming", " · itinérance") : ""))
}

func handleCheck() async {
    for r in await session.checkStack() {
        print("  \(r.ok ? "✅" : "❌") \(r.label): \(r.detail)")
    }
}

func handleVoices() {
    for lang in [session.speechLocale, "en-US"] {
        for v in TTSPlayer.availableVoices(language: lang) {
            print("  \(v.name) [\(v.language)] — \(v.identifier)")
        }
    }
    print(L("Main voice: export PHONEBT_VOICE=\"<name or identifier>\"", "Voix principale : export PHONEBT_VOICE=\"<nom ou identifiant>\""))
}

func handleAgentMode(autoAnswer: Bool) async {
    do {
        try await session.startAgent(autoAnswer: autoAnswer)
    } catch {
        print(error.localizedDescription)
        return
    }

    print(L("\nAgent mode — free-text instruction, '> text' to speak, '# 123' for keys, 'exit' to quit\n", "\nMode agent — instruction en texte libre, '> texte' pour parler, '# 123' pour les touches, 'exit' pour quitter\n"))
    while true {
        print("agent> ", terminator: "")
        fflush(stdout)
        guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { break }
        if line.isEmpty { continue }

        if line.lowercased() == "exit" {
            session.stopAgent()
            break
        } else if line.hasPrefix(">") {
            session.say(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
        } else if line.hasPrefix("#") {
            session.pressKeys(String(line.dropFirst()))
        } else {
            await session.sendToAgent(line)
        }
    }
}

// MARK: - Main Loop

printBanner()
printHelp()

AudioCapture.requestAuthorization { _ in }

Task {
    while true {
        print("phonebt> ", terminator: "")
        fflush(stdout)
        guard let line = readLine() else { break }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0].lowercased()
        let argument = parts.count > 1 ? parts[1] : ""

        switch command {
        case "scan":
            print(L("Searching (10 s)…", "Recherche (10 s)…"))
            devices = (try? await session.scan()) ?? []
            printDevices()
        case "paired":
            devices = session.pairedPhones()
            printDevices()
        case "connect":
            guard let i = Int(argument), devices.indices.contains(i) else {
                print(L("Invalid index. Run 'paired' first.", "Index invalide. Lance 'paired' d'abord."))
                continue
            }
            do { try await session.connect(to: devices[i]) } catch { print(L("Connection failed: ", "Connexion échouée : ") + error.localizedDescription) }
        case "disconnect":
            session.disconnect()
        case "dial", "call":
            session.dial(argument)
        case "answer", "accept":
            session.answer()
        case "hangup", "end":
            session.hangup()
        case "keys", "dtmf":
            session.pressKeys(argument)
        case "say":
            session.say(argument)
        case "status":
            handleStatus()
        case "phone":
            handlePhone()
        case "check":
            await handleCheck()
        case "voices":
            handleVoices()
        case "profile":
            print(L("Profile: ", "Dossier perso : ") + "\(session.config.profilePath) (" + (session.loadProfile().isEmpty ? L("empty", "vide") : L("filled in", "rempli")) + ")")
        case "agent", "ai":
            await handleAgentMode(autoAnswer: argument.lowercased() == "auto")
        case "help":
            printHelp()
        case "quit", "exit", "q":
            session.shutdown()
            exit(0)
        default:
            print(L("Unknown command: \(command). Type 'help'.", "Commande inconnue : \(command). Tape 'help'."))
        }
    }
    session.shutdown()
    exit(0)
}

// Keep the run loop alive for Bluetooth callbacks
RunLoop.main.run()
