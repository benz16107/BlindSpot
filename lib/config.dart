/// Central app config: API keys and object-detection model, prompt, and parameters.
/// Set API keys via --dart-define (e.g. flutter run --dart-define=GOOGLE_API_KEY=your_key)
/// or use .env.local.template as a guide — never commit real keys to a public repo.

// ═══════════════════════════════════════════════════════════════════════════════
// API KEYS (set via --dart-define; no defaults to avoid exposing keys in git)
// ═══════════════════════════════════════════════════════════════════════════════

/// Token server URL (used when not using in-app LiveKit token).
const String tokenUrl = String.fromEnvironment(
  'TOKEN_URL',
  defaultValue: 'http://localhost:8765/token',
);

/// Google AI API key. Used for in-app obstacle detection (Gemini). Set via --dart-define=GOOGLE_API_KEY=...
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

bool get useLocalObstacleDetection => googleApiKey.trim().isNotEmpty;

bool get useLocalLiveKitToken =>
    liveKitUrl.trim().isNotEmpty &&
    liveKitApiKey.trim().isNotEmpty &&
    liveKitApiSecret.trim().isNotEmpty;

// ═══════════════════════════════════════════════════════════════════════════════
// OBJECT DETECTION — model, prompt, and parameters
// ═══════════════════════════════════════════════════════════════════════════════

/// Gemini model used for obstacle detection when running in-app.
const String obstacleModel = 'gemini-2.0-flash';

/// Temperature for obstacle JSON generation (lower = more deterministic).
const double obstacleTemperature = 0.2;

/// HTTP/timeout for obstacle request (seconds).
const int obstacleRequestTimeoutSeconds = 8;

/// How often to run obstacle check (milliseconds). Lower = faster updates, more API use (e.g. 400–600).
const int obstacleCheckIntervalMs = 500;

/// Max width for image sent to Gemini. Larger = better detection, slower (256–512).
const int obstacleImageMaxWidth = 384;

/// JPEG quality when resizing (1–100). Lower = smaller payload.
const int obstacleJpegQuality = 75;

/// Cap output tokens so the model returns quickly.
const int obstacleMaxOutputTokens = 64;

/// Minimum time between repeated voice announcements for the same obstacle (seconds).
const int obstacleAnnounceCooldownSeconds = 4;

/// Haptic pulse interval while obstacle is near (milliseconds).
const int obstacleHapticPeriodMs = 350;

/// Distance values that trigger alert. Add 'far' for earlier warning.
const List<String> obstacleAlertDistances = ['near', 'medium', 'far'];

/// Short prompt for low latency. Model returns JSON only. Tuned for sensitivity.
const String obstaclePrompt =
    r'''Phone back camera, blind pedestrian. JSON only.
Rule: obstacle_detected true if any object in center of path ahead. "near"=immediate (under 1m), "medium"=2–5 m, "far"=5–15 m. Else false, "none". Prefer detecting obstacles.
Keys: "obstacle_detected" (bool), "distance" ("none"|"far"|"medium"|"near"), "description" (short, e.g. "pole", "person", "car" or "").''';
