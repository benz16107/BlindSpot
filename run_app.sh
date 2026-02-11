#!/bin/bash
# Run the Flutter phone app with API keys from .env.local.
#
# Uses --dart-define-from-file (same as run_flutter.sh) so keys are passed
# exactly as in .env.local, avoiding shell-escaping issues.
#
# Usage: ./run_app.sh [flutter run args...]
#
# For voice to work you also need the agent: ./run_agent.sh (in another terminal).

set -e
cd "$(dirname "$0")"

if [ ! -f .env.local ]; then
  echo "No .env.local found. Copy .env.local.template to .env.local and add LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET."
  echo "Then run ./run_app.sh again."
  exit 1
fi

# Build dart_defines.json from .env.local (same format/mechanism as run_flutter.sh)
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

flutter run --dart-define-from-file="$DART_DEFINES" "$@"
