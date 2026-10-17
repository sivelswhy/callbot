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

/// Language of the app and of everything the agent tells the user (reports, questions,
/// translations of the call). The call itself is in whatever language the caller speaks.
public enum UILanguage: String, CaseIterable, Sendable {
    case en
    case fr

    public var displayName: String {
        switch self {
        case .en: return "English"
        case .fr: return "Français"
        }
    }

    /// Name of the language in English, for the agent's instructions
    public var englishName: String {
        switch self {
        case .en: return "English"
        case .fr: return "French"
        }
    }

    private static let lock = NSLock()
    private static var stored: UILanguage = initial()

    /// Current language (thread-safe)
    public static var current: UILanguage {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    /// CALLBOT_UI_LANG, else the language saved in the app, else the system language
    private static func initial() -> UILanguage {
        if let env = ProcessInfo.processInfo.environment["CALLBOT_UI_LANG"], let lang = UILanguage(rawValue: env.lowercased()) {
            return lang
        }
        if let saved = UserDefaults.standard.string(forKey: "uiLanguage"), let lang = UILanguage(rawValue: saved) {
            return lang
        }
        return Locale.preferredLanguages.first?.hasPrefix("fr") == true ? .fr : .en
    }
}

extension UILanguage {
    private static let agentLock = NSLock()
    private static var storedAgent: UILanguage = {
        if let env = ProcessInfo.processInfo.environment["CALLBOT_AGENT_LANG"], let lang = UILanguage(rawValue: env.lowercased()) {
            return lang
        }
        if let saved = UserDefaults.standard.string(forKey: "agentLanguage"), let lang = UILanguage(rawValue: saved) {
            return lang
        }
        return current
    }()

    /// Language of the agent: how it talks to the user, the language of the call translations,
    /// and its default voice / greeting before the caller's language is known
    public static var agent: UILanguage {
        get { agentLock.lock(); defer { agentLock.unlock() }; return storedAgent }
        set { agentLock.lock(); storedAgent = newValue; agentLock.unlock() }
    }

    /// Default speech locale for this language
    public var locale: String {
        switch self {
        case .en: return "en-US"
        case .fr: return "fr-FR"
        }
    }
}

/// Text in the current app language
public func L(_ en: String, _ fr: String) -> String {
    UILanguage.current == .fr ? fr : en
}
