#!/usr/bin/env bash
# Exports the web build and zips it for itch.io upload.
# itch.io requires index.html at the zip root, hence build/web/.
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

WEB_DIR="$SCRIPT_DIR/build/web"
ZIP="$SCRIPT_DIR/build/dronesim-web.zip"

rm -rf "$WEB_DIR"
mkdir -p "$WEB_DIR"
"$GODOT_BIN" --headless --path "$SCRIPT_DIR" --export-release dronesim "$WEB_DIR/index.html"

rm -f "$ZIP"
(cd "$WEB_DIR" && zip -q -r "$ZIP" .)
echo "ready: $ZIP"
