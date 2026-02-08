/// App config. For a physical device, set [tokenUrl] to your computer's LAN URL
/// (e.g. http://192.168.1.100:8765/token) so the app can reach the token server.
const String tokenUrl = String.fromEnvironment(
  'TOKEN_URL',
  defaultValue: 'http://localhost:8765/token',
);

/// Obstacle server runs on a separate port (only holds GOOGLE_API_KEY). Same host as token URL.
const int obstacleServerPort = 8766;
