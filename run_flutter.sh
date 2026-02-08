#!/bin/bash
# Run Flutter app with API keys from dart_defines.json (gitignored).
# Copy dart_defines.json.example to dart_defines.json and add your keys.
cd "$(dirname "$0")"
if [ -f dart_defines.json ]; then
  exec flutter run --dart-define-from-file=dart_defines.json "$@"
else
  echo "dart_defines.json not found. Copy dart_defines.json.example to dart_defines.json and add your keys."
  exec flutter run "$@"
fi
