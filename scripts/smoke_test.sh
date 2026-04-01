#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY="$PROJECT_DIR/.build/debug/VitaPetApp"

echo "=== VitaPet Smoke Test ==="

# Step 1: Build
echo "[1/4] Building..."
cd "$PROJECT_DIR"
swift build --product VitaPetApp 2>&1 | tail -1
echo "      Build OK"

# Step 2: Launch
echo "[2/4] Launching app..."
"$BINARY" &
APP_PID=$!
sleep 3

# Step 3: Check process alive
echo "[3/4] Checking process..."
if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "      FAIL: App crashed or exited within 3 seconds"
    exit 1
fi
echo "      Process $APP_PID alive"

# Step 4: Check window exists (optional, needs Accessibility permission)
WINDOW_CHECK="skipped"
if command -v osascript &>/dev/null; then
    WINDOW_COUNT=$(osascript -e "
        tell application \"System Events\"
            try
                return count of windows of (first process whose unix id is $APP_PID)
            on error
                return -1
            end try
        end tell
    " 2>/dev/null || echo "-1")

    if [ "$WINDOW_COUNT" -ge 1 ] 2>/dev/null; then
        WINDOW_CHECK="$WINDOW_COUNT window(s) found"
    elif [ "$WINDOW_COUNT" = "-1" ]; then
        WINDOW_CHECK="skipped (no Accessibility permission)"
    else
        WINDOW_CHECK="warning: 0 windows"
    fi
fi
echo "      Window check: $WINDOW_CHECK"

# Cleanup
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true

echo ""
echo "=== PASS ==="
