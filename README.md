# Callbot — local AI phone agent for macOS

[![Build](https://github.com/sivelswhy/callbot/actions/workflows/build.yml/badge.svg)](https://github.com/sivelswhy/callbot/actions/workflows/build.yml)

> ⚠️ **Beta.** This project is under active development: expect bugs, behavior changes and
> settings that move between versions. Always keep an eye on what the agent says and does
> during a call.

Callbot turns a Mac paired with an iPhone into a phone assistant: an AI agent places and
receives calls over the phone's cellular line, listens to the other party, answers out loud,
navigates voice menus ("press 1…") and asks for your input when it's missing information.
Everything runs **locally**: LLM through Ollama, transcription through whisper.cpp, speech
synthesis from macOS. No API key needed.

This project is based on [PhoneBT by ICOA](https://github.com/icoainc/phonebt), a Bluetooth
hands-free (HFP) client for macOS, whose Bluetooth core it reuses.

## How it works

```
iPhone ──(Continuity "Calls on Other Devices")──► FaceTime on the Mac
                                                     │
     call audio ──► system audio capture ──► Whisper (transcription, detected language)
                                                     │
                                                     ▼
                                       local LLM (Ollama) + tools
                                                     │
     agent's voice ◄── BlackHole 16ch ◄── macOS speech synthesis
```

- **Call control**: the Mac is paired with the iPhone over Bluetooth (hands-free profile) to
  follow the call state, hang up and send DTMF keys.
- **Audio**: the call goes through macOS Continuity. The agent hears the call through a
  system audio capture (macOS 14.2+) and speaks into the call through the BlackHole 16ch
  virtual device, which FaceTime uses as its microphone.
- **Listening in**: you hear the call (other party + agent) on the Mac's speakers or
  headphones, and you can step in at any time: say a sentence, press keys, give the agent an
  instruction.

## Languages

- **App language**: English or French, in the app (bottom of the sidebar) or with
  `CALLBOT_UI_LANG=en|fr`. Defaults to the system language.
- **Agent language**: English or French, in the *AI agent* section or with
  `CALLBOT_AGENT_LANG=en|fr`. It's the language the agent uses with you (reports, questions),
  the language the call is translated into in the app, and the language it greets callers in.
- **Call language**: the agent answers in the other party's language, whatever it is. Whisper
  detects it automatically (English, French, Spanish, Arabic, Hebrew, Russian, German…), or
  you can set it in the app for more reliable transcription. When the call isn't in the agent
  language, each sentence is translated in the app, and what you type is translated before
  being spoken.

## Requirements

- macOS 14.2 or later, Apple Silicon Mac recommended (16 GB of RAM advised)
- An iPhone with **Calls on Other Devices** turned on (Settings › Phone), signed in to the
  same Apple Account and paired with the Mac over Bluetooth
- [Ollama](https://ollama.com) and a model that supports tools:
  ```bash
  ollama pull qwen3:8b
  ```
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and the `large-v3-turbo` model:
  ```bash
  brew install whisper-cpp
  mkdir -p ~/.callbot/models
  curl -L -o ~/.callbot/models/ggml-large-v3-turbo-q5_0.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
  ```
- [BlackHole](https://github.com/ExistentialAudio/BlackHole) 2ch and 16ch, then restart the Mac:
  ```bash
  brew install --cask blackhole-2ch blackhole-16ch
  ```
- A speech voice for each language you use: System Settings › Accessibility › Spoken
  Content › System Voice. "Enhanced" or "Premium" voices sound much better than the compact
  voices installed by default.

## Installation

```bash
git clone https://github.com/sivelswhy/callbot.git
cd callbot
./scripts/build-app.sh
open build/Callbot.app
```

A prebuilt `Callbot.app` is also attached to each [GitHub Actions run](https://github.com/sivelswhy/callbot/actions)
(unsigned: right-click › Open the first time).

On first launch, allow Callbot in System Settings › Privacy & Security:

| Permission | Why |
|---|---|
| Bluetooth | Call control with the iPhone |
| Microphone | Call audio capture |
| Screen & System Audio Recording ("System Audio Recording Only") | The agent hears the other party |
| Accessibility | Click "Call" / "Accept" in FaceTime automatically |

At launch, the app checks every component (Ollama, Whisper, BlackHole, voice, permissions)
and tells you what to fix; the **Check again** button runs the checks again.

> **Keep the permissions across rebuilds**: run `./scripts/setup-signing.sh` once (it creates
> a local signing certificate and asks for your password), then rebuild. Without it the app is
> signed ad hoc and macOS revokes Accessibility after each rebuild — the agent then can't press
> keys or click "Call" / "Accept".

## Usage

1. Open the app, choose your iPhone and connect.
2. Fill in **My info** (name, customer numbers…): the agent only uses this information and
   never makes up a number or an identifier.
3. Turn on the **agent**, then give it a mission ("Call my mobile carrier and ask for the
   details of my last bill") or let it answer incoming calls.
4. Follow the call live: transcription, translation, questions from the agent with clickable
   answers.

A command-line interface is also available: `swift run Callbot` (`help` lists the commands).

## Configuration

Optional environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `CALLBOT_UI_LANG` | system language | App language: `en` or `fr` |
| `CALLBOT_AGENT_LANG` | app language | Agent language: `en` or `fr` |
| `CALLBOT_MODEL` | `qwen3:8b` | Ollama model (`qwen3:4b-instruct`: twice as fast, much less reliable) |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama server |
| `CALLBOT_LOCALE` | agent language | Default speech locale (e.g. `en-GB`) |
| `CALLBOT_VOICE` | best installed voice | Speech voice (name or identifier) |
| `CALLBOT_VOICE_RATE` | `0.52` | Speech rate (0 to 1) |
| `CALLBOT_STT` | `whisper` | `whisper` (multilingual) or `apple` (single language) |
| `CALLBOT_WHISPER_MODEL` | `~/.callbot/models/ggml-large-v3-turbo-q5_0.bin` | Whisper model |
| `CALLBOT_WHISPER_LANG` | `auto` | Other party's language, or automatic detection |
| `CALLBOT_AUDIO` | `continuity` | `continuity` or `bluetooth` (SCO audio, refused by recent macOS) |
| `CALLBOT_PROFILE` | `~/.callbot/profile.md` | User info file |
| `CALLBOT_PROMPT_FILE` | — | Extra instructions for the agent |

The debug log is written to `~/.callbot/debug.log`.

## Project structure

```
Sources/
├── CallbotApp/      macOS app (SwiftUI)
├── Callbot/         Command-line interface
├── AgentBridge/     Call session, local agent (Ollama), tools, Continuity
├── AudioPipeline/   System capture, voice output, Whisper, speech synthesis, listening in
├── HFPCore/         Bluetooth hands-free (HFP): connection, call state, DTMF
└── Shared/          Models, localization and logging
```

## Known limitations

- **Beta**: tested on a limited number of Mac / iPhone setups.
- Small local models sometimes get things wrong (wrong menu key, answer outside the tools).
  Guards block the riskiest actions (made-up numbers, dialing during a call), but keep an eye
  on important calls.
- Dialing, answering and pressing keys go through the Mac's call window (Phone / FaceTime) with
  Accessibility: during a Continuity call, keys sent to the iPhone over Bluetooth are ignored.
  If a button isn't found, click it yourself.
- Direct Bluetooth SCO audio is refused by recent macOS versions: Continuity mode is the one
  that works.

## License

Apache License 2.0, see [LICENSE](LICENSE). Derived from
[icoainc/phonebt](https://github.com/icoainc/phonebt) (Copyright 2026 ICOA Inc.), modified:
local agent with Ollama, Whisper transcription, calls through Continuity, macOS app,
English/French interface.
