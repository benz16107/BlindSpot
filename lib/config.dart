/// Central app config: API keys and object-detection model, prompt, and parameters.
/// Set API keys via --dart-define (e.g. flutter run --dart-define=GOOGLE_API_KEY=your_key)
/// or use .env.local.template as a guide — never commit real keys to a public repo.
library;

// ═══════════════════════════════════════════════════════════════════════════════
// API KEYS (set via --dart-define; no defaults to avoid exposing keys in git)
// ═══════════════════════════════════════════════════════════════════════════════

/// Token server URL (used when not using in-app LiveKit token).
const String tokenUrl = String.fromEnvironment(
  'TOKEN_URL',
  defaultValue: 'http://localhost:8765/token',
);

/// Google AI API key. Used by agent for Gemini LLM. Set via --dart-define=GOOGLE_API_KEY=...
const String googleApiKey = String.fromEnvironment(
  'GOOGLE_API_KEY',
  defaultValue: '',
);

/// LiveKit server URL. Must match LIVEKIT_URL in .env.local used by agent.py.
const String liveKitUrl = String.fromEnvironment(
  'LIVEKIT_URL',
  defaultValue: '',
);

/// LiveKit API key. Set via --dart-define=LIVEKIT_API_KEY=...
const String liveKitApiKey = String.fromEnvironment(
  'LIVEKIT_API_KEY',
  defaultValue: '',
);

/// LiveKit API secret. Set via --dart-define=LIVEKIT_API_SECRET=...
const String liveKitApiSecret = String.fromEnvironment(
  'LIVEKIT_API_SECRET',
  defaultValue: '',
);

bool get useLocalLiveKitToken =>
    liveKitUrl.trim().isNotEmpty &&
    liveKitApiKey.trim().isNotEmpty &&
    liveKitApiSecret.trim().isNotEmpty;

// ═══════════════════════════════════════════════════════════════════════════════
// OBSTACLE DETECTION (camera frames → agent → OpenAI gpt-4o-mini vision)
// ═══════════════════════════════════════════════════════════════════════════════

/// How often to capture and send a frame to the agent (ms). Lower = faster response.
const int obstacleCheckIntervalMs = 400;

/// Max width for resized JPEG. Keep under ~10KB raw for LiveKit (14KB payload limit).
/// 256 gives HOG/YOLO enough resolution to detect; test_obstacle_local uses full frame (~640px).
const int obstacleImageMaxWidth = 256;

/// JPEG quality 1–100. Lower = smaller payload for LiveKit.
const int obstacleJpegQuality = 40;

/// Haptic pulse interval while obstacle is detected (ms).
const int obstacleHapticPeriodMs = 350;

/// If no update received for this long while in obstacle state, auto-clear (handles stuck model).
const int obstacleStaleClearMs = 2500;
