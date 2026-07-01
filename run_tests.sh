#!/usr/bin/env bash
# Runs the headless flight-mode test suite.
# Locates the Godot binary via PATH, falling back to the macOS .app bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT_APP_BIN="/Applications/Godot.app/Contents/MacOS/Godot"

if command -v godot >/dev/null 2>&1; then
  GODOT_BIN="godot"
elif [ -x "$GODOT_APP_BIN" ]; then
  GODOT_BIN="$GODOT_APP_BIN"
else
  echo "error: godot not found on PATH or at $GODOT_APP_BIN" >&2
  exit 1
fi

"$GODOT_BIN" --headless --path "$SCRIPT_DIR" scenes/test/flight_mode_test_scene.tscn
