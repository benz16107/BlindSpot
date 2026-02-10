#!/bin/bash
# Run the voice agent worker for the phone app.
# Use this when testing with the Flutter app on your phone — the agent registers
# with LiveKit and receives dispatch when the phone connects.
#
# For local testing with your computer's mic/speaker, use: uv run agent.py console
#
# Usage: ./run_agent.sh [agent.py dev args...]
# Example: ./run_agent.sh
#
# Requires: .env.local with LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET

set -e
cd "$(dirname "$0")"

# Load .env.local (same as agent.py and run_app.sh)
if [ -f .env.local ]; then
  set -a
  # shellcheck disable=SC1091
  source <(grep -v '^#' .env.local | grep -v '^$' | sed 's/^/export /')
  set +a
fi

echo "Starting agent worker for phone (connects to LiveKit, receives dispatch when app joins)..."
echo "For local mic/speaker testing instead, run: uv run agent.py console"
echo ""

exec uv run agent.py dev "$@"
