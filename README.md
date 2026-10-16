# PhoneBT — agent téléphonique IA local pour macOS

> ⚠️ **Bêta.** Le projet est en développement actif : attends-toi à des bugs, à des
> changements de comportement et à des réglages qui bougent d'une version à l'autre.
> Vérifie toujours ce que l'agent dit et fait pendant un appel.

PhoneBT transforme un Mac relié à un iPhone en assistant téléphonique : un agent IA passe
et reçoit des appels avec la ligne cellulaire du téléphone, écoute l'interlocuteur, lui
répond à voix haute, navigue dans les serveurs vocaux (« tapez 1… ») et te demande ton avis
quand il lui manque une information. Tout tourne **en local** : LLM via Ollama,
transcription via whisper.cpp, synthèse vocale de macOS. Aucune clé d'API n'est nécessaire.

Ce projet est basé sur [PhoneBT d'ICOA](https://github.com/icoainc/phonebt), un client
Bluetooth mains-libres (HFP) pour macOS, dont il reprend le cœur Bluetooth.

[![Build](https://github.com/sivelswhy/callbot/actions/workflows/build.yml/badge.svg)](https://github.com/sivelswhy/callbot/actions/workflows/build.yml)

## Fonctionnement

```
iPhone ──(Continuité « Appels sur le Mac »)──► FaceTime sur le Mac
                                                  │
     son de l'appel ──► capture audio système ──► Whisper (transcription, langue détectée)
                                                  │
                                                  ▼
                                    LLM local (Ollama) + outils
                                                  │
     voix de l'agent ◄── BlackHole 16ch ◄── synthèse vocale macOS
```

- **Contrôle de l'appel** : le Mac est jumelé à l'iPhone en Bluetooth (profil mains-libres)
  pour suivre l'état de l'appel, raccrocher et envoyer des touches DTMF.
- **Audio** : l'appel passe par la fonction Continuité de macOS. L'agent entend l'appel grâce
  à une capture de l'audio système (macOS 14.2+) et parle dans l'appel via le périphérique
  virtuel BlackHole 16ch, utilisé comme micro par FaceTime.
- **Écoute** : tu entends l'appel (interlocuteur + agent) sur les haut-parleurs ou le casque
  du Mac, et tu peux intervenir à tout moment : dire une phrase, taper des touches, donner une
  instruction à l'agent.

## Langues

L'agent répond dans la langue de l'interlocuteur. Whisper détecte automatiquement la langue
(français, anglais, espagnol, arabe, hébreu, russe, allemand…), ou tu peux la fixer dans
l'app pour une transcription plus fiable. Quand l'appel n'est pas en français, chaque phrase
est traduite dans l'interface, et le texte que tu tapes en français est traduit avant d'être
prononcé. L'interface de l'app est en français.

## Prérequis

- macOS 14.2 ou plus récent, Mac Apple Silicon recommandé (16 Go de RAM conseillés)
- Un iPhone avec **Appels sur d'autres appareils** activé (Réglages › Téléphone), connecté
  au même compte Apple, et jumelé au Mac en Bluetooth
- [Ollama](https://ollama.com) et un modèle qui gère les outils :
  ```bash
  ollama pull qwen3:4b-instruct
  ```
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) et le modèle `large-v3-turbo` :
  ```bash
  brew install whisper-cpp
  mkdir -p ~/.phonebt/models
  curl -L -o ~/.phonebt/models/ggml-large-v3-turbo-q5_0.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
  ```
- [BlackHole](https://github.com/ExistentialAudio/BlackHole) 2ch et 16ch, puis redémarrer le Mac :
  ```bash
  brew install --cask blackhole-2ch blackhole-16ch
  ```
- Une voix de synthèse pour chaque langue utilisée : Réglages Système › Accessibilité ›
  Contenu énoncé › Voix du système. Les voix « améliorées » ou « premium » sonnent bien
  mieux que les voix compactes installées par défaut.

## Installation

```bash
git clone https://github.com/sivelswhy/callbot.git
cd callbot
./scripts/build-app.sh
open build/PhoneBT.app
```

Au premier lancement, autorise PhoneBT dans Réglages Système › Confidentialité et sécurité :

| Autorisation | Pourquoi |
|---|---|
| Bluetooth | Contrôle de l'appel avec l'iPhone |
| Micro | Capture audio de l'appel |
| Enregistrement de l'écran et de l'audio système (« Audio système uniquement ») | L'agent entend l'interlocuteur |
| Accessibilité | Cliquer « Appeler » / « Accepter » dans FaceTime automatiquement |

Au démarrage, l'app vérifie chaque élément (Ollama, Whisper, BlackHole, voix, autorisations)
et indique quoi corriger ; le bouton **Revérifier** relance le contrôle.

> L'app est signée localement (ad hoc). Après une recompilation, macOS peut redemander
> certaines autorisations.

## Utilisation

1. Ouvre l'app, choisis ton iPhone et connecte-toi.
2. Remplis ton **profil** (nom, numéros client…) : l'agent n'utilise que ces informations,
   il n'invente jamais un numéro ni un identifiant.
3. Active l'**agent**, puis donne-lui une mission (« Appelle mon opérateur pour demander le
   détail de ma dernière facture ») ou laisse-le décrocher les appels entrants.
4. Suis l'appel en direct : transcription, traduction, questions de l'agent avec réponses
   cliquables.

Une interface en ligne de commande est aussi disponible : `swift run PhoneBT` (`help` pour la
liste des commandes).

## Configuration

Variables d'environnement facultatives :

| Variable | Défaut | Rôle |
|---|---|---|
| `PHONEBT_MODEL` | `qwen3:4b-instruct` | Modèle Ollama (`qwen3:8b` : plus fiable, deux fois plus lent) |
| `OLLAMA_HOST` | `http://localhost:11434` | Serveur Ollama |
| `PHONEBT_LOCALE` | `fr-FR` | Langue principale (voix par défaut) |
| `PHONEBT_VOICE` | meilleure voix installée | Voix de synthèse (nom ou identifiant) |
| `PHONEBT_VOICE_RATE` | `0.52` | Débit de la voix (0 à 1) |
| `PHONEBT_STT` | `whisper` | `whisper` (multilingue) ou `apple` (une seule langue) |
| `PHONEBT_WHISPER_MODEL` | `~/.phonebt/models/ggml-large-v3-turbo-q5_0.bin` | Modèle Whisper |
| `PHONEBT_WHISPER_LANG` | `auto` | Langue de l'interlocuteur, ou détection automatique |
| `PHONEBT_AUDIO` | `continuity` | `continuity` ou `bluetooth` (audio SCO, refusé par les macOS récents) |
| `PHONEBT_PROFILE` | `~/.phonebt/profile.md` | Fichier du profil utilisateur |
| `PHONEBT_PROMPT_FILE` | — | Instructions supplémentaires pour l'agent |

Le journal de débogage est écrit dans `~/.phonebt/debug.log`.

## Structure du projet

```
Sources/
├── PhoneBTApp/      App macOS (SwiftUI)
├── PhoneBT/         Interface en ligne de commande
├── AgentBridge/     Session d'appel, agent local (Ollama), outils, Continuité
├── AudioPipeline/   Capture système, sortie voix, Whisper, synthèse vocale, écoute
├── HFPCore/         Bluetooth mains-libres (HFP) : connexion, état d'appel, DTMF
└── Shared/          Modèles et journalisation
```

## Limites connues

- **Bêta** : testé sur un nombre limité de configurations Mac / iPhone.
- Les petits modèles locaux se trompent parfois (mauvaise touche de menu, réponse hors outil).
  Des garde-fous bloquent les actions les plus risquées (numéros inventés, composition
  pendant un appel), mais surveille les appels importants.
- Composer et décrocher automatiquement dépendent de l'interface de FaceTime (Accessibilité) ;
  si le bouton n'est pas trouvé, clique-le toi-même.
- L'audio Bluetooth SCO direct est refusé par les versions récentes de macOS : le mode
  Continuité est celui qui fonctionne.

## Licence

Apache License 2.0, voir [LICENSE](LICENSE). Projet dérivé de
[icoainc/phonebt](https://github.com/icoainc/phonebt) (Copyright 2026 ICOA Inc.), modifié :
agent local avec Ollama, transcription Whisper, appels via Continuité, app macOS.
