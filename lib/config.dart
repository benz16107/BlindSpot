/// App config. API keys set here = no local servers needed (obstacle + voice work in-app).
///
/// WARNING: This file contains secrets. Do not commit to a public repo, or add lib/config.dart to .gitignore.
const String tokenUrl = String.fromEnvironment(
  'TOKEN_URL',
  defaultValue: 'http://localhost:8765/token',
);

/// Gemini/Google AI API key. If set, obstacle detection runs in the app (no obstacle server).
const String googleApiKey = String.fromEnvironment(
  'GOOGLE_API_KEY',
  defaultValue: 'AIzaSyDeLs0ssVGAD5sXD3L_2Z7MDteJIJh06H8',
);

/// LiveKit server URL. With [liveKitApiKey] and [liveKitApiSecret], the app generates the token locally (no token server).
const String liveKitUrl = String.fromEnvironment(
  'LIVEKIT_URL',
  defaultValue: 'wss://testproject-o9b5hv33.livekit.cloud',
);

const String liveKitApiKey = String.fromEnvironment(
  'LIVEKIT_API_KEY',
  defaultValue: 'APInQ5xmbrKrfhK',
);

const String liveKitApiSecret = String.fromEnvironment(
  'LIVEKIT_API_SECRET',
  defaultValue: 'Q43HBNKeMWh4CG8MI235XKlZoAc5sgOcDYTRHyAIe7T',
);

bool get useLocalObstacleDetection => googleApiKey.trim().isNotEmpty;

bool get useLocalLiveKitToken =>
    liveKitUrl.trim().isNotEmpty &&
    liveKitApiKey.trim().isNotEmpty &&
    liveKitApiSecret.trim().isNotEmpty;

// --- Object detection sensitivity (lib/main.dart uses these) ---
/// Which distance values from the model trigger alert + haptic + voice.
/// Default: ['near', 'medium']. Add 'far' for higher sensitivity (more alerts, more false positives).
const List<String> obstacleAlertDistances = ['near', 'medium'];
