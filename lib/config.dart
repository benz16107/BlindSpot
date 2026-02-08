/// Central app config: API keys and object-detection model, prompt, and parameters.
/// Edit this file to change keys, obstacle sensitivity, and detection behavior.
///
/// WARNING: Default values may contain secrets. Do not commit real keys to a public repo.

// ═══════════════════════════════════════════════════════════════════════════════
// API KEYS (set via --dart-define or defaultValues below)
// ═══════════════════════════════════════════════════════════════════════════════

/// Token server URL (used when not using in-app LiveKit token).
const String tokenUrl = String.fromEnvironment(
  'TOKEN_URL',
  defaultValue: 'http://localhost:8765/token',
);

/// Google AI API key. Used for in-app obstacle detection (Gemini). Set via --dart-define=GOOGLE_API_KEY=...
const String googleApiKey = String.fromEnvironment(
  'GOOGLE_API_KEY',
  defaultValue: 'AIzaSyDeLs0ssVGAD5sXD3L_2Z7MDteJIJh06H8',
);

/// LiveKit server URL. Must match LIVEKIT_URL in .env.local used by agent.py so app and agent join the same cloud.
const String liveKitUrl = String.fromEnvironment(
  'LIVEKIT_URL',
  defaultValue: 'wss://testproject-o9b5hv33.livekit.cloud',
);

/// LiveKit API key. Set via --dart-define=LIVEKIT_API_KEY=...
const String liveKitApiKey = String.fromEnvironment(
  'LIVEKIT_API_KEY',
  defaultValue: 'APInQ5xmbrKrfhK',
);

/// LiveKit API secret. Set via --dart-define=LIVEKIT_API_SECRET=...
const String liveKitApiSecret = String.fromEnvironment(
  'LIVEKIT_API_SECRET',
  defaultValue: 'Q43HBNKeMWh4CG8MI235XKlZoAc5sgOcDYTRHyAIe7T',
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

/// Max width for image sent to Gemini. Smaller = faster upload and inference (e.g. 256).
const int obstacleImageMaxWidth = 256;

/// JPEG quality when resizing (1–100). Lower = smaller payload.
const int obstacleJpegQuality = 65;

/// Cap output tokens so the model returns quickly.
const int obstacleMaxOutputTokens = 64;

/// Minimum time between repeated voice announcements for the same obstacle (seconds).
const int obstacleAnnounceCooldownSeconds = 4;

/// Haptic pulse interval while obstacle is near (milliseconds).
const int obstacleHapticPeriodMs = 350;

/// Distance values that trigger alert (e.g. ['near', 'medium'] = alert within ~5 m).
const List<String> obstacleAlertDistances = ['near', 'medium'];

/// Short prompt for low latency. Model returns JSON only.
const String obstaclePrompt = r'''Phone back camera, blind pedestrian. JSON only.
Rule: obstacle_detected true only if object in center and close. "near"=very close, "medium"=2–5 m. Else false, "far"/"none". Ignore ground/sky/sides.
Keys: "obstacle_detected" (bool), "distance" ("none"|"far"|"medium"|"near"), "description" (short or "").''';
