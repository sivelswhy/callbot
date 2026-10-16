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

/// Tool definitions (Ollama / OpenAI function format) for the local agent to control phone calls
public enum PhoneTools {

    public static let allTools: [JSONValue] = [
        dialNumberTool,
        acceptCallTool,
        endCallTool,
        sendDTMFTool,
        getCallStatusTool,
        getPhoneStatusTool,
        sayToCallerTool,
        askUserTool,
    ]

    public static let dialNumberTool = function(
        name: "dial_number",
        description: "Dial a phone number to make an outgoing call. The number should be in a valid format (digits, optional + prefix, optional dashes/spaces).",
        properties: [
            "number": ["type": "string", "description": "The phone number to dial, e.g. '+33612345678' or '06 12 34 56 78'"],
        ],
        required: ["number"]
    )

    public static let acceptCallTool = function(
        name: "accept_call",
        description: "Accept/answer an incoming phone call."
    )

    public static let endCallTool = function(
        name: "end_call",
        description: "End/hang up the current active call."
    )

    public static let sendDTMFTool = function(
        name: "send_dtmf",
        description: "Press phone keys (DTMF) during an active call: navigate voice menus (\"press 1 for…\") or type a number the menu asks for (ID number, customer number, date of birth…), followed by # if requested.",
        properties: [
            "digits": ["type": "string", "description": "Keys to press, in order: 0-9, * and #. E.g. '1' or '123456789#'"],
        ],
        required: ["digits"]
    )

    public static let getCallStatusTool = function(
        name: "get_call_status",
        description: "Get the current call status including call state, direction, duration, and phone number."
    )

    public static let getPhoneStatusTool = function(
        name: "get_phone_status",
        description: "Get the phone's status including signal strength, battery level, service availability, operator name, and roaming status."
    )

    public static let sayToCallerTool = function(
        name: "say_to_caller",
        description: "Speak text to the caller during an active phone call using text-to-speech. The caller will hear your spoken words through the phone.",
        properties: [
            "text": ["type": "string", "description": "The text to speak to the caller, written in the language of the conversation"],
            "language": ["type": "string", "description": "ISO 639-1 code of the text's language, e.g. 'fr', 'he', 'en'"],
        ],
        required: ["text"]
    )

    public static let askUserTool = function(
        name: "ask_user",
        description: "Ask the user (the person you work for, watching the app) for information you don't have or a decision, e.g. which voice-menu option to choose, a code or a customer number. The answer arrives in a later message; meanwhile ask a human caller to hold on (never talk to a voice server).",
        properties: [
            "question": ["type": "string", "description": "The question for the user, in the user's language"],
            "options": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Optional short answers the user can click, in the user's language. For a voice menu, one per option with its key, e.g. '1 — service for this number'",
            ],
        ],
        required: ["question"]
    )

    private static func function(
        name: String,
        description: String,
        properties: [String: JSONValue] = [:],
        required: [String] = []
    ) -> JSONValue {
        [
            "type": "function",
            "function": [
                "name": .string(name),
                "description": .string(description),
                "parameters": [
                    "type": "object",
                    "properties": .object(properties),
                    "required": .array(required.map { .string($0) }),
                ],
            ],
        ]
    }
}
