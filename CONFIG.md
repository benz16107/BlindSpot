# Configuration & API Keys

Single place to see **where every API key and major setting lives**, and where to tune the **voice agent** and **object detection**.

---

## Where to view / set API keys

| Key / setting        | Used by        | Where to set / view |
|----------------------|----------------|----------------------|
| **GOOGLE_API_KEY**   | Agent (Gemini LLM); App (optional) | **`.env.local`** — `run_app.sh` passes to app |
| **LIVEKIT_URL**      | App (voice)    | **`.env.local`** — `run_app.sh` passes to app |
| **LIVEKIT_API_KEY**  | App (voice)    | **`.env.local`** — `run_app.sh` passes to app |
| **LIVEKIT_API_SECRET** | App (voice) | **`.env.local`** — `run_app.sh` passes to app |
| **TOKEN_URL**        | App (voice)    | `lib/config.dart` — only if not using in-app LiveKit token |
| **GOOGLE_MAPS_API_KEY** | Agent (navigation) | `.env.local` only |
| **ELEVEN_API_KEY**   | Agent (STT + TTS) | `.env.local` only |
| **ELEVEN_VOICE_ID**  | Agent (TTS)   | `.env.local` (optional; default in `agent_config.py`) |
| **ELEVEN_MODEL**     | Agent (TTS)   | `.env.local` (optional; default in `agent_config.py`) |
| **BACKBOARD_API_KEY**| Agent (memory, optional)| `.env.local` — omit to disable memory (no credits) |

- **All keys live in `.env.local`.** Copy `.env.local.template` to `.env.local` and fill in values. `.env.local` is gitignored.
- **Agent (Python)** reads `.env.local` (and `agent_config.py` for non-secret settings).
- **Flutter app** gets LiveKit/Google keys from `.env.local` when you run **`./run_app.sh`** (it passes them via `--dart-define`). Plain `flutter run` does not load `.env.local`, so use `./run_app.sh` for the phone app. For voice you also need **`./run_agent.sh`** (in another terminal).

---

## Agent & object detection — one place each

| What | File | What you can change |
|------|------|----------------------|
| **Voice agent** (model, prompts, VAD, STT, TTS, greeting) | **`agent_config.py`** | `AGENT_BASE_INSTRUCTIONS`, `LLM_MODEL`, `THINKING_BUDGET`, `STT_MODEL`, `STT_LANGUAGE`, `VAD_*`, `TTS_*`, `MEMORY_HISTORY_LIMIT`, `GREETING_*`, `OBSTACLE_PHRASE_TEMPLATE` |
| **Obstacle detection** (agent: frames → OpenCV HOG or YOLOv8n ONNX) | **`obstacle.py`** | `CENTER_*_FRAC`, `OBSTACLE_CLASS_IDS`; optional `yolov8n.onnx` in project root |
| **Obstacle frame capture** (app) | **`lib/config.dart`** | `obstacleCheckIntervalMs`, `obstacleImageMaxWidth`, `obstacleJpegQuality`, `obstacleHapticPeriodMs` |

- Edit **`agent_config.py`** to change the voice assistant’s instructions, LLM/STT/TTS models, and VAD/greeting parameters.
- Obstacle detection runs on the agent with **OpenCV** (no API key). Optionally place **`yolov8n.onnx`** in the project root for multi-class detection; otherwise HOG person detector is used. See **`scripts/download_yolov8n_onnx.py`** to generate the ONNX file.

---

## Quick reference: .env.local

**`.env.local.template`** has the same structure and variable order as **`.env.local`**. Copy the template to `.env.local` and fill in values:

| Variable | Purpose |
|----------|---------|
| `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | Voice: app + agent |
| `GOOGLE_API_KEY` | Gemini LLM (agent); also passed to app by `run_app.sh` |
| `GOOGLE_MAPS_API_KEY` | Navigation (agent) |
| `ELEVEN_API_KEY`, `ELEVEN_VOICE_ID`, `ELEVEN_MODEL` | Speech-to-text & text-to-speech (agent); voice/model optional |
| `BACKBOARD_API_KEY` | Memory (agent); optional |

**Do not commit `.env.local`** — it is in `.gitignore`.
