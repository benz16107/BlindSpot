#!/bin/bash
# Install the Flutter app in RELEASE mode so it works after you close it.
# Debug builds require a connection to your computer; release builds run standalone.
#
# Usage: ./run_app_release.sh
#
# Connect your phone via USB, run this once. After it installs, you can:
# - Disconnect USB
# - Close the app and reopen it from the home screen
# - It will keep working
#
# For voice to work you also need the agent: ./run_agent.sh (in another terminal).

set -e
cd "$(dirname "$0")"

if [ ! -f .env.local ]; then
  echo "No .env.local found. Copy .env.local.template to .env.local and add LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET."
  echo "Then run ./run_app_release.sh again."
  exit 1
fi

# Build dart_defines.json from .env.local
DART_DEFINES=$(mktemp)
trap 'rm -f "$DART_DEFINES"' EXIT
python3 -c "
import json, re
vars = {}
with open('.env.local') as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith('#'):
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line)
            if m:
                k, v = m.group(1), m.group(2).strip()
                if k in ('GOOGLE_API_KEY', 'LIVEKIT_URL', 'LIVEKIT_API_KEY', 'LIVEKIT_API_SECRET', 'TOKEN_URL'):
                    v = v.strip('\"').strip(\"'\")
                    vars[k] = v
print(json.dumps(vars))
" > "$DART_DEFINES"

echo "Installing RELEASE build (app will work after you close it)..."
echo "Select your iPhone when prompted."
echo ""
flutter run --release --dart-define-from-file="$DART_DEFINES" "$@"
