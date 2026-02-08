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

/// LiveKit server URL. Set via --dart-define=LIVEKIT_URL=...
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

/// How often to run obstacle check (seconds between frames).
const int obstacleCheckIntervalSeconds = 1;

/// Minimum time between repeated voice announcements for the same obstacle (seconds).
const int obstacleAnnounceCooldownSeconds = 4;

/// Haptic pulse interval while obstacle is near (milliseconds).
const int obstacleHapticPeriodMs = 350;

/// Distance values that trigger alert (e.g. ['near', 'medium'] = alert within ~5 m).
const List<String> obstacleAlertDistances = ['near', 'medium'];

/// System prompt sent to Gemini for each camera frame. Change rules and distance wording here.
const String obstaclePrompt = r'''
You are analyzing a single JPEG image from a smartphone's BACK CAMERA held by a blind pedestrian.

RULES — only alert when BOTH conditions are met:
1. The object is DIRECTLY in front: in the center of the frame (middle third of the image, especially lower center). If it is to the left or right of center, say obstacle_detected false.
2. The object is within about 5 meters: use "near" for within ~2 m (very close), "medium" for ~2–5 m. If it appears farther than 5 m (small in frame), say obstacle_detected false and distance "none" or "far".

- "obstacle_detected": true ONLY when the object is centered AND within ~5 m. Otherwise false.
- "distance": "near" when within ~2 m and centered; "medium" when ~2–5 m and centered. Use "none" or "far" when beyond 5 m and set obstacle_detected to false.
- Do NOT report: ground, sky, pavement, things to the side, or anything farther than ~5 m. When in doubt, say false (fewer false alarms).

Reply with JSON only, no other text, with these exact keys:
- "obstacle_detected": true or false
- "distance": one of "none", "far", "medium", "near"
- "description": short phrase (e.g. "pole", "person") or empty if none
''';
