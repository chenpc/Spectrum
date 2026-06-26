#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Spectrum"
APP_PATH="$SCRIPT_DIR/build/DerivedData/Build/Products/Debug/$APP_NAME.app"
BINARY="$APP_PATH/Contents/MacOS/$APP_NAME"

# ── Parse arguments ───────────────────────────────────────────────────────────

BUILD_ARGS=()
APP_ARGS=("--log-stdout")

usage() {
    echo "Usage: $0 [build-options] [app-options]"
    echo ""
    echo "Build options:"
    echo "  -c, --clean       Clean build before launching"
    echo "  -v, --verbose     Show full xcodebuild output"
    echo ""
    echo "App options:"
    echo "  --add-folder PATH Auto-add folder on launch"
    echo "  --userdir PATH    Override library/UserDefaults root"
    echo ""
    echo "Logs stream to stdout by default. Ctrl-C to quit."
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--clean)   BUILD_ARGS+=("$1"); shift ;;
        -v|--verbose) BUILD_ARGS+=("$1"); shift ;;
        -h|--help)    usage; exit 0 ;;
        --add-folder) APP_ARGS+=("$1" "$2"); shift 2 ;;
        --userdir)    APP_ARGS+=("$1" "$2"); shift 2 ;;
        *)            echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ── Build ─────────────────────────────────────────────────────────────────────

"$SCRIPT_DIR/build.sh" "${BUILD_ARGS[@]}" || exit 1

# ── Kill existing instance ────────────────────────────────────────────────────

if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "==> Killing running $APP_NAME..."
    pkill -x "$APP_NAME" || true
    sleep 0.5
fi

# ── Launch (binary directly so logs stream to this terminal) ──────────────────

echo "==> Launching $APP_NAME (Ctrl-C to quit)..."
exec "$BINARY" "${APP_ARGS[@]}"
