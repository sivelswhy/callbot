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

    func testDirectKeyCommands() {
        XCTAssertEqual(LocalAgent.directKeyCommand("appuie sur 1"), "1")
        XCTAssertEqual(LocalAgent.directKeyCommand("Appuis sur la touche 4."), "4")
        XCTAssertEqual(LocalAgent.directKeyCommand("press 3"), "3")
        XCTAssertEqual(LocalAgent.directKeyCommand("tape 2#"), "2#")
        XCTAssertNil(LocalAgent.directKeyCommand("appuie sur 1 et mets le français"))
        XCTAssertNil(LocalAgent.directKeyCommand("tape mon numéro client"))
    }

    func testDialOnlyMission() {
        XCTAssertTrue(LocalAgent.isDialOnly("Appelle le 3900"))
        XCTAssertTrue(LocalAgent.isDialOnly("call *166"))
        XCTAssertFalse(LocalAgent.isDialOnly("Appelle le 3900 et demande ma facture"))
    }

    func testMenuKeysDropUnaskedHash() {
        XCTAssertEqual(LocalAgent.menuKeys("4#", heard: "Pour le français, appuyez sur 4"), "4")
        XCTAssertEqual(LocalAgent.menuKeys("4#", heard: "Tapez 4 suivi de dièse"), "4#")
        XCTAssertEqual(LocalAgent.menuKeys("123#", heard: "Saisissez votre code"), "123#")
    }

    func testKnownNumbersAreWholeNumbers() {
        let numbers = LocalAgent.numbers(in: "ID : 123 456 789\nTéléphone : 06-12-34-56-78")
        XCTAssertTrue(numbers.contains("123456789"))
        XCTAssertTrue(numbers.contains("0612345678"))
        XCTAssertFalse(numbers.contains("12345678"))
    }

    func testInformationIsNotAMenu() {
        XCTAssertFalse(LocalAgent.looksLikeMenu("Nos bureaux sont ouverts du dimanche au jeudi de 9h à 18h."))
        XCTAssertTrue(LocalAgent.looksLikeMenu("Veuillez saisir votre numéro d'identité"))
    }

    func testInfoOnlyMission() {
        XCTAssertTrue(LocalAgent.isInfoOnly("appelle le *2994 et dis moi ce que c'est"))
        XCTAssertTrue(LocalAgent.isInfoOnly("Appelle *2994 (avec l'étoile) et dis moi c'est quoi"))
        XCTAssertFalse(LocalAgent.isInfoOnly("Appelle le 3900 et demande ma facture"))
    }

    func testLanguageMenu() {
        XCTAssertTrue(LocalAgent.isLanguageMenu("For English, press two. Для получения информации на русском языке"))
        XCTAssertTrue(LocalAgent.isLanguageMenu("Pour le français tapez 4, for English press 2"))
        XCTAssertFalse(LocalAgent.isLanguageMenu("To arrange an appointment, please press one"))
    }
}
