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

import SwiftUI
import AppKit
import HFPCore
import AgentBridge
import Shared

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 340)
        } detail: {
            ConversationView()
                // The detail toolbar background is drawn a few points left of the sidebar
                // divider (misaligned junction): let the window background show instead
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .sheet(isPresented: $model.showProfile) {
            ProfileEditor()
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                phoneSection
                agentSection
                callSection
                if model.isConnected { Keypad() }
                checksSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 46)      // just below the window buttons
            .padding(.bottom, 16)
        }
        // The sidebar reserves the toolbar's height plus extra space: start right under the
        // window buttons instead
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: Phone

    private var phoneSection: some View {
        SectionBox(title: "Téléphone") {
            if model.isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "iphone").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.connectedName ?? "iPhone").lineLimit(1)
                        if let phone = model.state?.phoneStatus {
                            Text([phone.operatorName, "réseau \(phone.signalStrength)/5", "batterie \(phone.batteryLevel)/5"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Déconnecter") { model.toggleConnection() }
                        .controlSize(.small)
                }
            } else {
                HStack {
                    Picker("", selection: $model.selectedAddress) {
                        if model.devices.isEmpty {
                            Text("Aucun iPhone appairé").tag(String?.none)
                        }
                        ForEach(model.devices, id: \.address) { d in
                            Text(d.name).tag(Optional(d.address))
                        }
                    }
                    .labelsHidden()

                    Button {
                        model.refreshDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Actualiser la liste")
                }

                Button {
                    model.toggleConnection()
                } label: {
                    HStack {
                        if model.isConnecting { ProgressView().controlSize(.small) }
                        Text(model.isConnecting ? "Connexion…" : "Connecter")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isConnecting || model.selectedAddress == nil)
            }
        }
    }

    // MARK: Agent

    private var agentSection: some View {
        SectionBox(title: "Agent IA") {
            Toggle(isOn: Binding(
                get: { model.agentEnabled },
                set: { model.agentEnabled = $0; model.setAgent(enabled: $0) }
            )) {
                HStack(spacing: 6) {
                    Text(model.agentEnabled ? "Actif" : "Inactif")
                    if model.agentStarting { ProgressView().controlSize(.small) }
                }
            }
            .toggleStyle(.switch)
            .disabled(!model.isConnected || model.agentStarting)
            .help(model.isConnected ? "L'agent passe et reçoit les appels pour toi" : "Connecte d'abord ton iPhone")

            Toggle("Répondre aux appels entrants", isOn: $model.autoAnswer)
                .onChange(of: model.autoAnswer) { _ in model.restartAgentIfRunning() }
                .help("L'agent décroche lui-même et demande l'objet de l'appel")

            Button {
                model.showProfile = true
            } label: {
                Label("Mes infos…", systemImage: "person.text.rectangle")
            }
            .buttonStyle(.link)
            .help("Nom, numéros de client… utilisés par l'agent pour tes démarches")
        }
    }

    // MARK: Call

    private var callSection: some View {
        SectionBox(title: "Appel") {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText).lineLimit(1)
                Spacer()
                if let duration = model.state?.activeCall?.durationDescription {
                    Text(duration).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            if model.inCall {
                HStack {
                    if model.callStatus == .incoming {
                        Button {
                            model.session.answer()
                        } label: {
                            Label("Décrocher", systemImage: "phone.fill").frame(maxWidth: .infinity)
                        }
                        .tint(.green)
                    }
                    Button(role: .destructive) {
                        model.session.hangup()
                    } label: {
                        Label("Raccrocher", systemImage: "phone.down.fill").frame(maxWidth: .infinity)
                    }
                    .tint(.red)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if model.isConnected {
                HStack {
                    TextField("Numéro à appeler", text: $model.dialNumber)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .onSubmit { model.dial() }
                    Button {
                        model.dial()
                    } label: {
                        Image(systemName: "phone.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .help("Appeler")
                    .disabled(model.dialNumber.isEmpty)
                }
            }

            Picker("Langue", selection: $model.callLanguage) {
                Text("Automatique").tag("auto")
                Divider()
                Text("Allemand").tag("de")
                Text("Anglais").tag("en")
                Text("Arabe").tag("ar")
                Text("Espagnol").tag("es")
                Text("Français").tag("fr")
                Text("Hébreu").tag("he")
                Text("Italien").tag("it")
                Text("Portugais").tag("pt")
                Text("Russe").tag("ru")
            }
            .help("Langue de l'interlocuteur. La choisir rend la transcription plus fiable que la détection automatique.")

            HStack(spacing: 8) {
                Toggle(isOn: $model.monitorEnabled) {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Entendre l'appel et la voix de l'agent sur le Mac")
                Slider(value: $model.monitorVolume, in: 0...1)
                    .controlSize(.small)
                    .disabled(!model.monitorEnabled)
                    .help("Volume d'écoute")
            }
        }
    }

    // MARK: Checks

    private var checksSection: some View {
        let problems = model.checks.filter { !$0.ok }
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { model.showChecks.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: problems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.checks.isEmpty ? .secondary : problems.isEmpty ? Color.green : Color.orange)
                    Text(model.checks.isEmpty ? "Vérification…"
                         : problems.isEmpty ? "Tout est prêt"
                         : "\(problems.count) point\(problems.count > 1 ? "s" : "") à régler")
                    Spacer()
                    Text(model.showChecks ? "Masquer" : "Détails")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.showChecks ? 90 : 0))
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.showChecks {
                ForEach(model.checks, id: \.label) { check in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: check.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(check.ok ? .green : .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(check.label).font(.callout)
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !check.ok, let url = Self.settingsURL(for: check.label) {
                                Button("Ouvrir les réglages") { NSWorkspace.shared.open(url) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                Button("Revérifier") { Task { await model.runChecks() } }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    /// System Settings pane that fixes a failed check
    private static func settingsURL(for label: String) -> URL? {
        let pane: String
        switch label {
        case "Accessibilité": pane = "Privacy_Accessibility"
        case "Bluetooth": pane = "Privacy_Bluetooth"
        default: return nil
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    private var statusText: String {
        guard model.isConnected else { return "iPhone non connecté" }
        let number = model.state?.activeCall?.number.flatMap { $0.isEmpty ? nil : $0 }
        switch model.callStatus {
        case .idle: return "Prêt"
        case .incoming: return "Appel entrant\(number.map { " · \($0)" } ?? "")"
        case .dialing, .alerting: return "Ça sonne…"
        case .active: return "En ligne\(number.map { " · \($0)" } ?? "")"
        case .held: return "En attente"
        default: return model.callStatus.rawValue
        }
    }

    private var statusColor: Color {
        guard model.isConnected else { return .gray }
        switch model.callStatus {
        case .idle: return .blue
        case .incoming, .dialing, .alerting, .held: return .orange
        default: return .green
        }
    }
}

private struct Keypad: View {
    @EnvironmentObject var model: AppModel
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]

    var body: some View {
        SectionBox(title: model.inCall ? "Touches (envoyées dans l'appel)" : "Clavier") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        model.keypadPressed(key)
                    } label: {
                        Text(key)
                            .font(.title3.monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if !model.inCall && !model.dialNumber.isEmpty {
                Button("Effacer") { model.dialNumber.removeLast() }
                    .controlSize(.small)
            }
        }
    }
}

private struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

// MARK: - Conversation

private struct ConversationView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.log.isEmpty {
                            EmptyState()
                        }
                        ForEach(model.log) { entry in
                            LogRow(entry: entry).id(entry.id)
                        }
                        if model.agentThinking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("L'agent réfléchit…").foregroundStyle(.secondary)
                            }
                            .id("thinking")
                        }
                    }
                    .padding(20)
                }
                .onChange(of: model.log.count) { _ in
                    withAnimation { proxy.scrollTo(model.log.last?.id, anchor: .bottom) }
                }
            }

            if let question = model.pendingQuestion {
                HStack(alignment: .top) {
                    Image(systemName: "questionmark.bubble.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("L'agent a besoin de toi").font(.callout.weight(.semibold))
                        Text(question)
                    }
                    Spacer()
                    Button("Répondre") { model.questionPopup = question }
                        .controlSize(.small)
                    Button {
                        model.pendingQuestion = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Ignorer")
                }
                .padding(12)
                .background(.orange.opacity(0.12))
            }

            Divider()
            inputBar
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.clearLog()
                } label: {
                    Label("Nouvelle conversation", systemImage: "square.and.pencil")
                }
                .help("Effacer le fil et réinitialiser la mémoire de l'agent")
            }
        }
        .onChange(of: model.pendingQuestion) { q in
            if q != nil { inputFocused = true }
        }
        .sheet(isPresented: Binding(
            get: { model.questionPopup != nil },
            set: { if !$0 { model.questionPopup = nil } }
        )) {
            QuestionPopup(question: model.questionPopup ?? "")
                .environmentObject(model)
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $model.inputMode) {
                ForEach(AppModel.InputMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)

            HStack {
                TextField(placeholder, text: $model.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit { model.submitInput() }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

                Button {
                    model.submitInput()
                } label: {
                    Image(systemName: model.inputMode == .say ? "speaker.wave.2.fill" : "arrow.up")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.inputText.trimmingCharacters(in: .whitespaces).isEmpty || !canSend)
            }
        }
        .padding(14)
    }

    private var canSend: Bool {
        switch model.inputMode {
        case .agent: return model.agentEnabled
        case .say: return model.audioConnected
        }
    }

    private var placeholder: String {
        switch model.inputMode {
        case .agent:
            return model.agentEnabled
                ? "Ex : Appelle le 03-1234567 et résilie mon abonnement internet"
                : "Active l'agent pour lui donner des instructions"
        case .say:
            guard model.audioConnected else { return "Disponible pendant un appel" }
            if let lang = model.session.callTargetLanguage, !lang.hasPrefix("fr") {
                return "Écris en français : traduit en \(PhoneSession.languageName(lang)) et dit dans l'appel"
            }
            return "Texte dit à voix haute dans l'appel"
        }
    }
}

private struct EmptyState: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "phone.bubble.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("Ton assistant téléphonique").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Connecte ton iPhone", done: model.isConnected)
                step(2, "Active l'agent", done: model.agentEnabled)
                step(3, "Donne-lui une mission ci-dessous", done: false)
            }
            Text("Ex : « Appelle le *444 et demande le prix des appels vers la France ». Pendant l'appel, tu suis la conversation ici, traduite en français, et l'agent te demande ton avis s'il hésite.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 60)
        .frame(maxWidth: 460, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func step(_ n: Int, _ text: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .font(.title3)
            Text(text).foregroundStyle(done ? .secondary : .primary)
        }
    }
}

private struct LogRow: View {
    let entry: SessionLogEntry

    var body: some View {
        switch entry.kind {
        case .system, .error, .keys:
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(entry.kind == .keys ? "Touches : \(entry.text)" : entry.text)
            }
            .font(.caption)
            .foregroundStyle(entry.kind == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, alignment: .center)
            .textSelection(.enabled)

        default:
            HStack {
                if alignRight { Spacer(minLength: 80) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(entry.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let translation = entry.translation {
                        Text("🇫🇷 \(translation)")
                            .font(.callout.italic())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(background))
                if !alignRight { Spacer(minLength: 80) }
            }
        }
    }

    /// Our side (agent / user) on the right, the other party and reports on the left
    private var alignRight: Bool {
        switch entry.kind {
        case .agentSpoke, .userSpoke, .user: return true
        default: return false
        }
    }

    private var title: String {
        switch entry.kind {
        case .caller(let lang): return "Interlocuteur\(lang.map { " · \(Self.languageLabel($0))" } ?? "")"
        case .agentSpoke: return "Agent (dit dans l'appel)"
        case .agent: return "Agent → toi"
        case .question: return "❓ Question de l'agent"
        case .user: return "Toi → agent"
        case .userSpoke: return "Toi (dit dans l'appel)"
        default: return ""
        }
    }

    private var background: Color {
        switch entry.kind {
        case .caller: return Color.secondary.opacity(0.12)
        case .agentSpoke: return Color.accentColor.opacity(0.18)
        case .userSpoke: return Color.green.opacity(0.18)
        case .user: return Color.secondary.opacity(0.08)
        case .question: return Color.orange.opacity(0.18)
        default: return Color.purple.opacity(0.10)
        }
    }

    private var icon: String {
        switch entry.kind {
        case .error: return "exclamationmark.triangle"
        case .keys: return "circle.grid.3x3"
        default: return "info.circle"
        }
    }

    static func languageLabel(_ code: String) -> String {
        PhoneSession.languageName(code)
    }
}

// MARK: - Agent question

/// Pop-up shown when the agent asks the user something (ask_user)
private struct QuestionPopup: View {
    @EnvironmentObject var model: AppModel
    let question: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("L'agent a besoin de toi").font(.title3.weight(.semibold))
                    if model.inCall {
                        Text("Appel en cours — l'interlocuteur attend").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(question)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !model.questionOptions.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.questionOptions, id: \.self) { option in
                        Button {
                            model.chooseOption(option)
                        } label: {
                            Text(option)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .controlSize(.large)
                    }
                }
            }
            TextField(model.questionOptions.isEmpty ? "Ta réponse…" : "Ou réponds autre chose…", text: $model.questionAnswer, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { model.answerQuestion(model.questionAnswer) }
            HStack {
                Button("Plus tard") { model.questionPopup = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Répondre") { model.answerQuestion(model.questionAnswer) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.questionAnswer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { focused = true }
    }
}

// MARK: - Profile

private struct ProfileEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mes infos").font(.title2.weight(.semibold))
            Text("L'agent utilise ces informations pour tes démarches (opérateur, banque, administration…). Elles restent sur ce Mac et ne sont communiquées que si l'interlocuteur en a besoin.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $model.profileText)
                .font(.body.monospaced())
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                .frame(minHeight: 320)

            HStack {
                if model.profileText.isEmpty {
                    Button("Insérer un modèle") { model.profileText = Self.template }
                }
                Spacer()
                Button("Annuler") {
                    model.profileText = model.session.loadProfile()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    model.saveProfile()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    static let template = """
        Nom complet :
        Date de naissance :
        Numéro d'identité :
        Adresse :
        Email :
        Téléphone :

        Opérateur mobile / numéro client :
        Fournisseur internet / numéro client :
        Banque / numéro de compte :

        Langues parlées :
        Préférences : être poli mais ferme, demander un numéro de dossier à chaque fois
        """
}
