#!/usr/bin/env bash
# Runs the headless test suites.
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

status=0

echo "=== Flight mode test suite ==="
"$GODOT_BIN" --headless --path "$SCRIPT_DIR" scenes/test/flight_mode_test_scene.tscn || status=1

echo "=== Wind field test suite ==="
"$GODOT_BIN" --headless --path "$SCRIPT_DIR" scenes/test/wind_test_scene.tscn || status=1

echo "=== Flight recorder test suite ==="
"$GODOT_BIN" --headless --path "$SCRIPT_DIR" scenes/test/flight_recorder_test_scene.tscn || status=1

echo "=== OSM terrain test suite ==="
"$GODOT_BIN" --headless --path "$SCRIPT_DIR" scenes/test/osm_terrain_test_scene.tscn || status=1

exit $status
