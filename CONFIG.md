# Configuration & API Keys

Single place to see **where every API key and major setting lives**, and where to tune the **voice agent** and **object detection**.

---

## Where to view / set API keys

| Key / setting        | Used by        | Where to set / view |
|----------------------|----------------|----------------------|
| **GOOGLE_API_KEY**   | App (obstacle), Agent (Gemini) | **App:** `lib/config.dart` (or `--dart-define=GOOGLE_API_KEY=...`). **Agent:** `.env.local` |
| **LIVEKIT_URL**      | App (voice)    | `lib/config.dart` or `--dart-define` |
| **LIVEKIT_API_KEY**  | App (voice)    | `lib/config.dart` or `--dart-define` |
| **LIVEKIT_API_SECRET** | App (voice) | `lib/config.dart` or `--dart-define` |
| **TOKEN_URL**        | App (voice)    | `lib/config.dart` — only if not using in-app LiveKit token |
| **GOOGLE_MAPS_API_KEY** | Agent (navigation) | `.env.local` only |
| **DEEPGRAM_API_KEY** | Agent (STT)    | `.env.local` only |
| **ELEVEN_API_KEY**   | Agent (TTS)   | `.env.local` only |
| **ELEVEN_VOICE_ID**  | Agent (TTS)   | `.env.local` (optional; default in `agent_config.py`) |
| **ELEVEN_MODEL**     | Agent (TTS)   | `.env.local` (optional; default in `agent_config.py`) |
| **ZAPIER_MCP_URL**   | Agent (MCP)   | `.env.local` only |
| **ZAPIER_MCP_TOKEN** | Agent (MCP)   | `.env.local` only |
| **BACKBOARD_API_KEY**| Agent (memory)| `.env.local` only |

- **Flutter app** reads: `lib/config.dart` and build-time `--dart-define`. It does **not** read `.env.local`. **No keys are stored in `config.dart`** — use `--dart-define` to avoid exposing keys in git.
- **Agent (Python)** reads: `.env.local` (and `agent_config.py` for non-secret settings). Copy `.env.local.template` to `.env.local` and fill in values. `.env.local` is gitignored.

**Running the Flutter app with keys:**
```bash
# Option A: Use run script (recommended — no long command)
./run_flutter.sh

# Option B: Copy dart_defines.json.example to dart_defines.json, add your keys, then:
flutter run --dart-define-from-file=dart_defines.json

# Option C: Pass defines inline
flutter run --dart-define=GOOGLE_API_KEY=xxx --dart-define=LIVEKIT_URL=xxx --dart-define=LIVEKIT_API_KEY=xxx --dart-define=LIVEKIT_API_SECRET=xxx
```

`dart_defines.json` is gitignored — copy `dart_defines.json.example` to `dart_defines.json` and add your keys.

---

## Agent & object detection — one place each

| What | File | What you can change |
|------|------|----------------------|
| **Voice agent** (model, prompts, VAD, TTS, greeting) | **`agent_config.py`** | `AGENT_BASE_INSTRUCTIONS`, `LLM_MODEL`, `THINKING_BUDGET`, `STT_MODEL`, `STT_LANGUAGE`, `VAD_*`, `TTS_*`, `MEMORY_HISTORY_LIMIT`, `GREETING_*`, `OBSTACLE_PHRASE_TEMPLATE` |
| **Object detection** (model, prompt, intervals, sensitivity) | **`lib/config.dart`** | `obstacleModel`, `obstacleTemperature`, `obstaclePrompt`, `obstacleCheckIntervalSeconds`, `obstacleAnnounceCooldownSeconds`, `obstacleHapticPeriodMs`, `obstacleAlertDistances`, `obstacleRequestTimeoutSeconds` |

- Edit **`agent_config.py`** to change the voice assistant’s instructions, LLM/STT/TTS models, and VAD/greeting parameters.
- Edit **`lib/config.dart`** to change obstacle detection model, prompt, timing, and which distances trigger alerts.

---

## Quick reference: .env.local

Template: **`.env.local.template`**. Copy to **`.env.local`** and set:

- `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` — if you use a token server or same keys as app
- `GOOGLE_API_KEY` — Gemini (agent + optional obstacle server)
- `GOOGLE_MAPS_API_KEY` — navigation
- `DEEPGRAM_API_KEY` — speech-to-text
- `ELEVEN_API_KEY` — text-to-speech
- `ZAPIER_MCP_URL`, `ZAPIER_MCP_TOKEN` — optional Zapier MCP
- `BACKBOARD_API_KEY` — optional memory

**Do not commit `.env.local`** — it is in `.gitignore`. Use `.env.local.template` as a guide and add your own keys locally.
