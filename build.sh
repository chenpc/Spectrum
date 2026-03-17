#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$SCRIPT_DIR/Spectrum.xcodeproj"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="Spectrum"
LOG="$BUILD_DIR/build-debug.log"

# ── Parse arguments ──────────────────────────────────────────────────────────

CLEAN=0
OPEN=0
VERBOSE=0

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -c, --clean     Clean build (remove DerivedData)"
    echo "  -o, --open      Open the app after build"
    echo "  -v, --verbose   Show full xcodebuild output"
    echo "  -h, --help      Show this help"
    echo ""
    echo "Output: build/DerivedData/Build/Products/Debug/Spectrum.app"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--clean)   CLEAN=1; shift ;;
        -o|--open)    OPEN=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ── Clean (optional) ─────────────────────────────────────────────────────────

if [ "$CLEAN" -eq 1 ]; then
    echo "==> Cleaning previous build..."
    rm -rf "$BUILD_DIR/DerivedData"
fi

mkdir -p "$BUILD_DIR"

# ── Build ────────────────────────────────────────────────────────────────────

echo "==> Building Debug (incremental, $(sysctl -n hw.logicalcpu) cores)..."

XCODEBUILD_CMD=(
    xcodebuild -project "$PROJECT"
    -scheme "$APP_NAME"
    -configuration Debug
    -derivedDataPath "$BUILD_DIR/DerivedData"
)

if [ "$VERBOSE" -eq 1 ]; then
    "${XCODEBUILD_CMD[@]}" 2>&1 | tee "$LOG"
else
    "${XCODEBUILD_CMD[@]}" 2>&1 | tee "$LOG" | grep -E "^(error:|warning: |note: Bundled|note: Building|Build succeeded|Build FAILED|\*\* BUILD)" || true
fi

# ── Verify ───────────────────────────────────────────────────────────────────

if ! grep -q "BUILD SUCCEEDED" "$LOG"; then
    echo ""
    echo "✗ Build failed. Errors:"
    grep "error:" "$LOG" | head -20
    echo ""
    echo "Full log: $LOG"
    exit 1
fi

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Debug/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: $APP_NAME.app not found at expected path"
    exit 1
fi

APP_SIZE=$(du -sh "$APP_PATH" | cut -f1)
echo ""
echo "✓ BUILD SUCCEEDED — $APP_PATH ($APP_SIZE)"

# ── Bundled libs summary ─────────────────────────────────────────────────────

LIB_DIR="$APP_PATH/Contents/Resources/lib"
if [ -d "$LIB_DIR" ]; then
    LIB_COUNT=$(ls -1 "$LIB_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ')
    echo "  $LIB_COUNT dylibs in Resources/lib/"
fi

# ── Open (optional) ──────────────────────────────────────────────────────────

if [ "$OPEN" -eq 1 ]; then
    echo "==> Opening $APP_NAME.app..."
    open "$APP_PATH"
fi
