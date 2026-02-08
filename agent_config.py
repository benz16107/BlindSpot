"""
Central config for the voice agent: model names, prompts, and parameters.
Edit this file to change LLM, STT, TTS, VAD, and system instructions.
"""

# --- System instructions (voice navigation assistant) ---
AGENT_BASE_INSTRUCTIONS = (
    "You are a concise voice walking navigation assistant for blind users. Multilingual. "
    "Phone sends live GPS. Use get_current_location for 'where am I?'. "
    "For 'navigate to X' or 'take me to Y' (with a specific address or place name) use start_navigation(origin='current location', destination=X or Y). Never ask for start address. "
    "For 'navigate to a nearby X', 'nearest Y', 'find a Z and take me there' use navigate_to_nearby(place_query) with just the place type (e.g. 'McDonald's', 'coffee shop', 'pharmacy') — do NOT use start_navigation with a vague destination like 'nearby McDonald's'. "
    "Turn-by-turn is automatic from GPS. Use Zapier tools when relevant. Keep replies brief."
)

# --- LLM (Gemini) ---
LLM_MODEL = "gemini-2.5-flash"
THINKING_BUDGET = 0  # 0 = no thinking, faster replies

# --- STT (Deepgram) ---
STT_MODEL = "nova-2"
STT_LANGUAGE = "en"

# --- TTS (ElevenLabs). Override with env: ELEVEN_VOICE_ID, ELEVEN_MODEL ---
TTS_VOICE_ID_DEFAULT = "EXAVITQu4vr4xnSDxMaL"
TTS_MODEL_DEFAULT = "eleven_multilingual_v2"

# --- VAD (turn detection). Lower = faster response, higher = fewer false triggers ---
VAD_MIN_SPEECH_DURATION = 0.3   # seconds before user turn is accepted
VAD_MIN_SILENCE_DURATION = 0.6  # seconds of silence before agent can respond
VAD_ACTIVATION_THRESHOLD = 0.65 # speech confidence to interrupt

# --- Memory (Backboard) ---
MEMORY_HISTORY_LIMIT = 10  # number of past messages to include in context

# --- Greeting ---
GREETING_DELAY_SECONDS = 2.0
GREETING_PHRASE = "Where would you like to go?"

# --- Obstacle voice (when app publishes obstacle_alert) ---
OBSTACLE_PHRASE_TEMPLATE = "Watch out. Obstacle detected. {description} in front."
