#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY="$PROJECT_DIR/.build/debug/VitaPetApp"

echo "=== Plugin System Smoke Test ==="

echo "[1/5] Building..."
cd "$PROJECT_DIR"
swift build --product VitaPetApp 2>&1 | tail -1

echo "[2/5] Skipping manual plugin creation (built-in plugins auto-install on launch)..."

echo "[3/5] Launching app..."
"$BINARY" &
APP_PID=$!
sleep 3

if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "FAIL: App crashed"
    exit 1
fi
echo "App running (PID $APP_PID)"

echo "[4/5] Checking built-in plugins installed and parseable..."
PLUGIN_DIR="$HOME/Library/Application Support/VitaPet/Plugins"
FOUND=0
PARSE_OK=0
for p in SitReminder GitCelebrateJSON HourlyChime BirthdayReminder; do
    MANIFEST="$PLUGIN_DIR/$p/plugin.json"
    if [ -f "$MANIFEST" ]; then
        echo "  Found: $p"
        FOUND=$((FOUND + 1))
        # Verify manifest is valid JSON with required fields
        if python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert 'id' in d and 'name' in d and 'triggers' in d, 'missing required fields'
" "$MANIFEST" 2>/dev/null; then
            echo "    Manifest: valid"
            PARSE_OK=$((PARSE_OK + 1))
        else
            echo "    Manifest: INVALID"
        fi
    else
        echo "  MISSING: $p"
    fi
done
if [ "$FOUND" -eq 0 ]; then
    echo "FAIL: No built-in plugins installed"
    kill "$APP_PID" 2>/dev/null || true
    exit 1
fi
if [ "$PARSE_OK" -ne "$FOUND" ]; then
    echo "FAIL: $((FOUND - PARSE_OK)) plugin(s) have invalid manifests"
    kill "$APP_PID" 2>/dev/null || true
    exit 1
fi
echo "Plugin check: $FOUND/$FOUND installed, all manifests valid"

echo "[5/5] Cleaning up..."
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true

echo "=== DONE ==="
