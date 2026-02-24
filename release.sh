#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$SCRIPT_DIR/Spectrum.xcodeproj"
BUILD_DIR="$SCRIPT_DIR/build"
DMG_STAGING="$BUILD_DIR/dmg-staging"
APP_NAME="Spectrum"
DMG_OUTPUT="$SCRIPT_DIR/$APP_NAME.dmg"
LOG="$BUILD_DIR/build.log"

echo "==> Cleaning previous build..."
rm -rf "$BUILD_DIR"
rm -f "$DMG_OUTPUT"
mkdir -p "$BUILD_DIR"

echo "==> Building Release (incremental, $(sysctl -n hw.logicalcpu) jobs)..."
xcodebuild -project "$PROJECT" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    SWIFT_COMPILATION_MODE=incremental \
    2>&1 | tee "$LOG" | grep -E "^(error:|warning: |note: Bundled|note: Added|Build succeeded|Build FAILED|\*\* BUILD)" || true

# Verify build succeeded
if ! grep -q "BUILD SUCCEEDED" "$LOG"; then
    echo ""
    echo "ERROR: Build failed. Full log: $LOG"
    grep "error:" "$LOG" | head -20
    exit 1
fi

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: $APP_NAME.app not found at expected path"
    exit 1
fi

# Verify libmpv was bundled
LIBMPV="$APP_PATH/Contents/Resources/lib/libmpv.dylib"
if [ -f "$LIBMPV" ]; then
    RPATH=$(otool -l "$LIBMPV" 2>/dev/null | grep -A2 "LC_RPATH" | grep "path" | awk '{print $2}' | head -1)
    echo "==> libmpv bundled: Resources/lib/libmpv.dylib (rpath: $RPATH)"
else
    echo "WARNING: libmpv.dylib not found in bundle — mpv player will be unavailable"
fi

# Verify libgyrocore was bundled
LIBGYRO="$APP_PATH/Contents/Resources/lib/libgyrocore_c.dylib"
if [ -f "$LIBGYRO" ]; then
    echo "==> libgyrocore bundled: Resources/lib/libgyrocore_c.dylib ($(ls -lh "$LIBGYRO" | awk '{print $5}'))"
else
    echo "WARNING: libgyrocore_c.dylib not found in bundle — gyro stabilization will be unavailable"
fi

echo "==> Creating DMG..."
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_OUTPUT"

echo "==> Cleaning up..."
rm -rf "$BUILD_DIR"

echo ""
echo "Done! DMG created at: $DMG_OUTPUT"
