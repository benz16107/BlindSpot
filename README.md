# cam_preview

Flutter app for assistive walking navigation: live camera, GPS, voice agent, obstacle detection, and haptics.

## How the server works

There are **two server processes** that run on your computer. The phone app talks to both (over Wi‑Fi when on a device).

```
                    ┌─────────────────────────────────────────────────────────┐
                    │  Your computer (same Wi‑Fi as phone)                     │
                    │                                                          │
   Phone app        │   ┌──────────────────┐      ┌────────────────────────┐  │
   ─────────        │   │  Token server    │      │  LiveKit agent         │  │
                    │   │  (token_server   │      │  (agent.py)            │  │
   ┌────────────┐   │   │   .py)           │      │                        │  │
   │ 1. GET      │───┼──►│  Port 8765      │      │  Connects to LiveKit   │  │
   │    /token   │   │   │                  │      │  cloud/server          │  │
   └────────────┘   │   │  Returns:        │      │  Joins same room as    │  │
                    │   │  • JWT token      │      │  the app               │  │
   ┌────────────┐   │   │  • LiveKit URL   │      │                        │  │
   │ 2. Connect  │───┼───┼──────────────────┼─────►  Voice: STT → LLM → TTS │  │
   │    to       │   │   │                  │      │  Tools: navigation,   │  │
   │    LiveKit  │   │   │                  │      │  GPS, obstacle_alert  │  │
   └────────────┘   │   │                  │      └────────────────────────┘  │
                    │   │  POST /obstacle- │                    ▲              │
   ┌────────────┐   │   │  frame (JPEG)    │                    │              │
   │ 3. POST     │───┼──►│  → Gemini →     │                    │              │
   │    camera   │   │   │  JSON (obstacle, │  App publishes     │              │
   │    frame    │   │   │  distance)       │  obstacle_alert   │              │
   └────────────┘   │   └──────────────────┘  on LiveKit ──────┘              │
                    └─────────────────────────────────────────────────────────┘
```

### 1. Token server (`token_server.py`) — port 8765

- **What it does:** Only loads **API keys** and issues tokens. Single endpoint:
  - **GET `/token`** — Returns a **LiveKit JWT** and **LiveKit URL** so the app can connect. No other logic.
- **Run:** `uv run python token_server.py`
- **Config (`.env.local`):** `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` only.

### 2. Obstacle server (`obstacle_server.py`) — port 8766

- **What it does:** Only loads **GOOGLE_API_KEY** and runs obstacle detection. Single endpoint:
  - **POST `/obstacle-frame`** — Body = JPEG. Calls Gemini, returns `obstacle_detected`, `distance`, `description`. App uses this for haptics and (when mic is on) sends result to the agent for voice alerts.
- **Run:** `uv run python obstacle_server.py`
- **Config (`.env.local`):** `GOOGLE_API_KEY` only.

### 3. LiveKit agent (`agent.py`)

- **What it does:** Connects to **LiveKit** (cloud or your server). When the app joins a room, LiveKit starts this worker; it joins the **same room** and runs the voice assistant:
  - **Voice:** Mic audio → **Deepgram (STT)** → **Gemini (LLM)** → **ElevenLabs (TTS)** → speaker.
  - **Data from app:** Listens for:
    - **`gps`** — lat/lng/heading; used for location and turn‑by‑turn.
    - **`obstacle_alert`** — when obstacle detection says “near”; agent speaks e.g. “Obstacle ahead, slow down.”
  - **Tools:** Navigation (Google Maps), nearby search, Backboard memory, optional Zapier MCP.
- **Run:** `uv run python agent.py dev` (or your LiveKit agent run command).
- **Config (`.env.local`):** LiveKit keys, `GOOGLE_API_KEY`, `GOOGLE_MAPS_API_KEY`, `DEEPGRAM_API_KEY`, `ELEVEN_API_KEY`, etc.

### 4. App (Flutter)

- Gets a token from the token server, then connects to **LiveKit** (voice + data).
- Sends **GPS** and (when obstacle is on) **camera frames** to the token server; receives obstacle JSON and triggers **haptics**; if mic is on, publishes **obstacle_alert** to LiveKit so the agent can announce it.
- On a **physical device**, set the server URL in the app to your computer’s IP (e.g. `http://192.168.1.x:8765/token`). Same host is used for `/obstacle-frame`.

### Summary

| You run              | Role | Keys |
|----------------------|------|------|
| `token_server.py`    | Issues LiveKit tokens only. | LIVEKIT_* only |
| `obstacle_server.py` | Obstacle detection (Gemini). | GOOGLE_API_KEY only |
| `agent.py`           | Voice assistant in LiveKit room. | Various (see agent) |

Run token server and obstacle server (and agent). App uses token URL for tokens and same host + port 8766 for obstacle.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
