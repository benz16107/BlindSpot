#!/bin/bash
# Run Flutter app with keys from .env.local (same file used by agent.py).
# Fixes: connection refused (use in-app LiveKit token, not localhost) and GOOGLE_API_KEY for obstacles.
#
# Usage: ./run_app.sh [flutter run args...]
# Example: ./run_app.sh --no-sound-null-safety
#
# Requires: .env.local with LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET, GOOGLE_API_KEY

set -e
cd "$(dirname "$0")"

# Load .env.local (strip comments and empty lines, export vars)
if [ -f .env.local ]; then
  set -a
  # shellcheck disable=SC1091
  source <(grep -v '^#' .env.local | grep -v '^$' | sed 's/^/export /')
  set +a
fi

# Pass keys to Flutter. Use empty string if not set (app will show setup prompts).
flutter run \
  --dart-define=GOOGLE_API_KEY="${GOOGLE_API_KEY:-}" \
  --dart-define=LIVEKIT_URL="${LIVEKIT_URL:-}" \
  --dart-define=LIVEKIT_API_KEY="${LIVEKIT_API_KEY:-}" \
  --dart-define=LIVEKIT_API_SECRET="${LIVEKIT_API_SECRET:-}" \
  "$@"
