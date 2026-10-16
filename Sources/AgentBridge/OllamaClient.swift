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

// MARK: - JSON value

/// Arbitrary JSON value, used for tool schemas and tool-call arguments
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    /// Convert to Foundation types, as expected by ToolExecutor
    public var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) : n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - Chat types (Ollama /api/chat)

public struct ChatMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: String
    public var toolCalls: [ToolCall]?
    public var toolName: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolName = "tool_name"
    }

    public init(role: String, content: String, toolCalls: [ToolCall]? = nil, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
    }
}

public struct ToolCall: Codable, Sendable, Equatable {
    public struct Function: Codable, Sendable, Equatable {
        public var name: String
        public var arguments: [String: JSONValue]

        public init(name: String, arguments: [String: JSONValue]) {
            self.name = name
            self.arguments = arguments
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            // Some models return arguments as a JSON-encoded string
            if let dict = try? c.decode([String: JSONValue].self, forKey: .arguments) {
                arguments = dict
            } else if let str = try? c.decode(String.self, forKey: .arguments),
                      let data = str.data(using: .utf8),
                      let dict = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
                arguments = dict
            } else {
                arguments = [:]
            }
        }
    }

    public var function: Function

    public init(function: Function) {
        self.function = function
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let tools: [JSONValue]
    let stream = false
    let think: Bool?
    let keepAlive: String
    let options: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream, think, options
        case keepAlive = "keep_alive"
    }
}

private struct ChatResponse: Decodable {
    let message: ChatMessage
}

// MARK: - Priority

/// Ollama answers one request at a time: a translation sent just before the agent's turn made
/// the agent wait ~1 s. Background requests (translations) wait until the agent is idle.
public enum OllamaPriority: Sendable {
    /// The agent's turn in the call
    case interactive
    /// Display-only work (translations)
    case background
}

private final class OllamaScheduler: @unchecked Sendable {
    static let shared = OllamaScheduler()
    private let lock = NSLock()
    private var interactive = 0

    func begin() { lock.lock(); interactive += 1; lock.unlock() }
    func end() { lock.lock(); interactive -= 1; lock.unlock() }

    /// Let the agent's request (triggered by the same caller speech) start, then wait for it
    func waitForIdle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
        var waited = 0
        while busy, waited < 300 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
    }

    private var busy: Bool { lock.lock(); defer { lock.unlock() }; return interactive > 0 }
}

// MARK: - Client

/// Minimal client for a local Ollama server (http://localhost:11434 by default)
public final class OllamaClient: @unchecked Sendable {
    public let baseURL: URL
    public let model: String
    private let session: URLSession
    /// Disabled automatically if the model rejects the `think` parameter
    private var sendThinkFlag = true

    public init(baseURL: URL, model: String) {
        self.baseURL = baseURL
        self.model = model
        let config = URLSessionConfiguration.default
        // First request may have to load the model into memory
        config.timeoutIntervalForRequest = 300
        self.session = URLSession(configuration: config)
    }

    /// Check that Ollama is reachable and the model is installed
    public func checkAvailability() async throws {
        let url = baseURL.appendingPathComponent("api/tags")
        let data: Data
        do {
            (data, _) = try await session.data(from: url)
        } catch {
            throw OllamaError.unreachable(baseURL.absoluteString)
        }
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        let tags = try JSONDecoder().decode(Tags.self, from: data)
        let names = tags.models.map(\.name)
        let wanted = model.contains(":") ? model : "\(model):latest"
        guard names.contains(wanted) else {
            throw OllamaError.modelMissing(model, installed: names)
        }
    }

    public func chat(messages: [ChatMessage], tools: [JSONValue], priority: OllamaPriority = .interactive) async throws -> ChatMessage {
        let scheduler = OllamaScheduler.shared
        if priority == .background {
            await scheduler.waitForIdle()
        } else {
            scheduler.begin()
        }
        defer { if priority == .interactive { scheduler.end() } }
        do {
            return try await send(messages: messages, tools: tools, think: sendThinkFlag ? false : nil)
        } catch OllamaError.httpError(let code, let body) where code == 400 && body.contains("think") {
            // Model doesn't support the thinking toggle — retry without it
            sendThinkFlag = false
            return try await send(messages: messages, tools: tools, think: nil)
        }
    }

    private func send(messages: [ChatMessage], tools: [JSONValue], think: Bool?) async throws -> ChatMessage {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: messages,
            tools: tools,
            think: think,
            keepAlive: "60m",
            options: ["temperature": .number(0.5), "num_ctx": .number(8192)]
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw OllamaError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        var message = try JSONDecoder().decode(ChatResponse.self, from: data).message
        message.content = Self.stripThinking(message.content)
        return message
    }

    /// Remove any `<think>…</think>` block a reasoning model may still emit
    static func stripThinking(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>") {
            if let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result.removeSubrange(start.lowerBound..<result.endIndex)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum OllamaError: Error, LocalizedError {
    case unreachable(String)
    case modelMissing(String, installed: [String])
    case invalidResponse
    case httpError(Int, String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let url):
            return "Ollama injoignable sur \(url) — lance-le avec `ollama serve` (ou l'app Ollama)."
        case .modelMissing(let model, let installed):
            return "Modèle '\(model)' absent. Installe-le avec `ollama pull \(model)`. Installés : \(installed.joined(separator: ", "))"
        case .invalidResponse:
            return "Réponse invalide d'Ollama"
        case .httpError(let code, let body):
            return "Erreur Ollama (\(code)) : \(body)"
        }
    }
}
