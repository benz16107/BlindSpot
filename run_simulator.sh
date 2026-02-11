#!/bin/bash
# Launch the iOS Simulator for Flutter development.
# Use this when "flutter emulators --launch apple_ios_simulator" doesn't work.
#
# Usage: ./run_simulator.sh [device name]
# Example: ./run_simulator.sh "iPhone 16"
# Example: ./run_simulator.sh "iPhone 15 Pro"

set -e
cd "$(dirname "$0")"

DEVICE="${1:-iPhone 16}"

echo "Booting iOS Simulator: $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true

echo "Opening Simulator app..."
open -a Simulator

echo "Simulator should be launching. Run ./run_app.sh when it's ready."
