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
@testable import AudioPipeline
import Shared

final class LocalFeaturesTests: XCTestCase {

    func testDTMFDigitsFiltering() {
        XCTAssertEqual(String(ToolExecutor.dtmfDigits("123 456-789#")), "123456789#")
        XCTAssertEqual(String(ToolExecutor.dtmfDigits("*0")), "*0")
        XCTAssertTrue(ToolExecutor.dtmfDigits("abc").isEmpty)
        // Non-ASCII digits (e.g. Arabic-Indic) are not valid DTMF
        XCTAssertTrue(ToolExecutor.dtmfDigits("١٢").isEmpty)
    }

    func testWaitMarker() {
        XCTAssertTrue(LocalAgent.isWaitMarker("ATTENTE"))
        XCTAssertTrue(LocalAgent.isWaitMarker("WAIT"))
        XCTAssertTrue(LocalAgent.isWaitMarker(" attente. "))
        XCTAssertTrue(LocalAgent.isWaitMarker(""))
        XCTAssertFalse(LocalAgent.isWaitMarker("Bonjour, en attente de votre réponse"))
    }

    func testSystemPromptIncludesProfile() {
        let prompt = LocalAgent.makeSystemPrompt(autoAnswer: true, userProfile: "Numéro d'identité : 123456789", extraInstructions: nil)
        XCTAssertTrue(prompt.contains("123456789"))
        XCTAssertTrue(prompt.contains("Auto-answer mode"))
        XCTAssertFalse(prompt.contains("{USER_LANGUAGE}"))
        XCTAssertTrue(prompt.contains(UILanguage.agent.englishName))
        XCTAssertFalse(LocalAgent.makeSystemPrompt(autoAnswer: false, userProfile: "  ", extraInstructions: nil).contains("Informations sur l'utilisateur"))
    }

    func testWhisperResponseParsing() throws {
        let json = #"{"text":"שלום, הגעתם לשירות\n הלקוחות","language":"hebrew"}"#
        let (text, lang) = try WhisperCapture.parseResponse(Data(json.utf8))
        XCTAssertEqual(text, "שלום, הגעתם לשירות הלקוחות")
        XCTAssertEqual(lang, "he")
    }

    func testWhisperHallucinationFilter() {
        XCTAssertNil(WhisperCapture.cleanTranscription("Sous-titrage ST' 501"))
        XCTAssertNil(WhisperCapture.cleanTranscription("[Musique]"))
        XCTAssertEqual(WhisperCapture.cleanTranscription(" Bonjour (bruit) "), "Bonjour")
    }

    func testWavHeader() {
        let wav = WhisperCapture.wavData(samples: [0, 0.5, -0.5], sampleRate: 16000)
        XCTAssertEqual(wav.count, 44 + 6)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
    }

    func testTTSLanguageDetection() {
        XCTAssertEqual(TTSPlayer.detectLanguage("שלום, אני רוצה לבטל את המנוי"), "he")
        XCTAssertEqual(TTSPlayer.detectLanguage("Bonjour, je voudrais résilier mon abonnement"), "fr")
    }
}
