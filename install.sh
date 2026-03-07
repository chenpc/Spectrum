#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$SCRIPT_DIR/Spectrum.xcodeproj"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="Spectrum"
LOG="$BUILD_DIR/build.log"

echo "==> Building Release..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild -project "$PROJECT" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    SWIFT_COMPILATION_MODE=incremental \
    2>&1 | tee "$LOG" | grep -E "^(error:|warning: |Build succeeded|Build FAILED|\*\* BUILD)" || true

if ! grep -q "BUILD SUCCEEDED" "$LOG"; then
    echo ""
    echo "ERROR: Build failed. Full log: $LOG"
    grep "error:" "$LOG" | head -20
    exit 1
fi

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: $APP_NAME.app not found"
    exit 1
fi

echo "==> Installing to /Applications/$APP_NAME.app..."
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_PATH" "/Applications/$APP_NAME.app"

echo "==> Cleaning up..."
rm -rf "$BUILD_DIR"

echo "Done! Installed: /Applications/$APP_NAME.app"
