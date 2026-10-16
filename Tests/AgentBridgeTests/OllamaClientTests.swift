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

import XCTest
@testable import AgentBridge

final class OllamaClientTests: XCTestCase {

    // MARK: - Response decoding

    func testDecodesToolCallWithObjectArguments() throws {
        let json = #"{"role":"assistant","content":"","tool_calls":[{"function":{"name":"dial_number","arguments":{"number":"+33612345678"}}}]}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.toolCalls?.first?.function.name, "dial_number")
        XCTAssertEqual(message.toolCalls?.first?.function.arguments["number"], .string("+33612345678"))
    }

    func testDecodesToolCallWithStringArguments() throws {
        let json = #"{"role":"assistant","content":"","tool_calls":[{"function":{"name":"send_dtmf","arguments":"{\"digit\":\"1\"}"}}]}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.toolCalls?.first?.function.arguments["digit"], .string("1"))
    }

    func testDecodesMessageWithoutContent() throws {
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"role":"assistant"}"#.utf8))
        XCTAssertEqual(message.content, "")
        XCTAssertNil(message.toolCalls)
    }

    func testJSONValueAnyConversion() {
        XCTAssertEqual(JSONValue.number(3).anyValue as? Int, 3)
        XCTAssertEqual(JSONValue.number(2.5).anyValue as? Double, 2.5)
        XCTAssertEqual(JSONValue.string("a").anyValue as? String, "a")
    }

    func testStripThinking() {
        XCTAssertEqual(OllamaClient.stripThinking("<think>hmm</think>\nBonjour"), "Bonjour")
        XCTAssertEqual(OllamaClient.stripThinking("Bonjour <think>unterminated"), "Bonjour")
        XCTAssertEqual(OllamaClient.stripThinking("Bonjour"), "Bonjour")
    }

    func testToolsEncodeAsFunctions() throws {
        let data = try JSONEncoder().encode(PhoneTools.allTools)
        let tools = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(tools.count, 8)
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains("say_to_caller"))
        XCTAssertTrue(tools.allSatisfy { $0["type"] as? String == "function" })
    }

    // MARK: - Live integration (skipped if Ollama isn't running)

    func testLiveModelSpeaksToCaller() async throws {
        let env = ProcessInfo.processInfo.environment
        let client = OllamaClient(
            baseURL: URL(string: env["OLLAMA_HOST"] ?? "http://localhost:11434")!,
            model: env["PHONEBT_MODEL"] ?? "qwen3:8b"
        )
        do {
            try await client.checkAvailability()
        } catch {
            throw XCTSkip("Ollama unavailable: \(error.localizedDescription)")
        }

        let messages = [
            ChatMessage(role: "system", content: LocalAgent.baseSystemPrompt),
            ChatMessage(role: "user", content: "[PHONE EVENT] Audio connecté"),
            ChatMessage(role: "user", content: #"[CALLER SPEECH] "Bonjour, je voudrais prendre rendez-vous pour jeudi""#),
        ]
        let start = Date()
        let response = try await client.chat(messages: messages, tools: PhoneTools.allTools)
        print("Live response in \(String(format: "%.1f", Date().timeIntervalSince(start)))s: \(response)")

        let call = try XCTUnwrap(response.toolCalls?.first, "model answered without a tool call: \(response.content)")
        XCTAssertEqual(call.function.name, "say_to_caller")
        XCTAssertFalse((call.function.arguments["text"]?.anyValue as? String ?? "").isEmpty)
    }

    func testLiveModelTypesIDOnForeignLanguageIVR() async throws {
        let env = ProcessInfo.processInfo.environment
        let client = OllamaClient(
            baseURL: URL(string: env["OLLAMA_HOST"] ?? "http://localhost:11434")!,
            model: env["PHONEBT_MODEL"] ?? "qwen3:8b"
        )
        do {
            try await client.checkAvailability()
        } catch {
            throw XCTSkip("Ollama unavailable: \(error.localizedDescription)")
        }

        let prompt = LocalAgent.makeSystemPrompt(
            autoAnswer: false, userProfile: "Numéro d'identité : 123456789", extraInstructions: nil
        )
        let messages = [
            ChatMessage(role: "system", content: prompt),
            ChatMessage(role: "user", content: "Appelle mon fournisseur internet au 199 pour connaître le solde de ma facture"),
            ChatMessage(role: "user", content: "[PHONE EVENT] Audio connecté"),
            ChatMessage(role: "user", content: #"[CALLER SPEECH lang=he] "נא הקישו את מספר תעודת הזהות ובסיומו סולמית""#),
        ]
        let response = try await client.chat(messages: messages, tools: PhoneTools.allTools)
        print("Live IVR response: \(response)")

        let call = try XCTUnwrap(response.toolCalls?.first, "no tool call: \(response.content)")
        XCTAssertEqual(call.function.name, "send_dtmf")
        let digits = (call.function.arguments["digits"]?.anyValue).map { "\($0)" } ?? ""
        XCTAssertEqual(String(ToolExecutor.dtmfDigits(digits)), "123456789#")
    }
}
