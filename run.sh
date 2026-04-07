#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Spectrum"
APP_PATH="$SCRIPT_DIR/build/DerivedData/Build/Products/Debug/$APP_NAME.app"

# ── Build ────────────────────────────────────────────────────────────────────

"$SCRIPT_DIR/build.sh" "$@" || exit 1

# ── Kill existing instance ───────────────────────────────────────────────────

if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "==> Killing running $APP_NAME..."
    pkill -x "$APP_NAME" || true
    sleep 0.5
fi

# ── Launch ───────────────────────────────────────────────────────────────────

echo "==> Launching $APP_NAME..."
open "$APP_PATH"
