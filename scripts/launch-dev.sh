#!/bin/bash
# Launch cmux DEV from DerivedData with the required CMUX_TAG.
# Usage: ./scripts/launch-dev.sh [tag-name]
#
# The Debug build refuses to start without CMUX_TAG set (safety guard).
# This script handles that so you can just double-click or run it.
#
# Also strips CLAUDECODE env var so Claude Code can run inside cmux DEV
# terminals (otherwise it thinks it's nested and refuses to start).

set -euo pipefail

TAG="${1:-dev-test}"
APP_NAME="cmux DEV"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"

# Find the GhosttyTabs DerivedData directory
DD_DIR=$(ls -dt "$DERIVED_DATA"/GhosttyTabs-* 2>/dev/null | head -1)
APP_PATH="$DD_DIR/Build/Products/Debug/$APP_NAME.app"

if [ -z "$DD_DIR" ] || [ ! -d "$APP_PATH" ]; then
    echo "Error: '$APP_NAME.app' not found in DerivedData. Build it first:"
    echo "  cd $(cd "$(dirname "$0")/.."; pwd)"
    echo "  xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug build"
    exit 1
fi

BINARY="$APP_PATH/Contents/MacOS/$APP_NAME"

if [ ! -x "$BINARY" ]; then
    echo "Error: Binary not found at: $BINARY"
    exit 1
fi

# Gracefully quit any existing instance (Cmd+Q via AppleScript)
# This lets the app run applicationWillTerminate() and save scrollback.
# Falls back to SIGTERM if AppleScript fails.
BUNDLE_ID="com.cmuxterm.app.debug"
if pgrep -f "$APP_NAME" >/dev/null 2>&1; then
    echo "Quitting existing instance gracefully..."
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
    # Wait up to 5 seconds for graceful shutdown
    for i in $(seq 1 10); do
        pgrep -f "$APP_NAME" >/dev/null 2>&1 || break
        sleep 0.5
    done
    # Force kill if still running
    if pgrep -f "$APP_NAME" >/dev/null 2>&1; then
        echo "Graceful quit timed out, force killing..."
        pkill -9 -f "$APP_NAME" 2>/dev/null || true
        sleep 1
    fi
fi

echo "Launching: $APP_PATH"
echo "Tag: $TAG"

# Launch with clean env: set CMUX_TAG, strip CLAUDECODE
# Run in background and detach so this script can exit
env -u CLAUDECODE CMUX_TAG="$TAG" "$BINARY" &>/dev/null &
disown

echo "PID: $!"
echo "Done. cmux DEV should appear shortly."
