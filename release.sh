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

# Download pre-built dylibs if not present
if [ ! -f "$SCRIPT_DIR/Spectrum/Resources/lib/libmpv.dylib" ]; then
    echo "==> Downloading pre-built dependencies..."
    "$SCRIPT_DIR/download_libs.sh"
fi

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

# Verify mpv dylibs were bundled
LIB_DIR="$APP_PATH/Contents/Resources/lib"
LIBMPV="$LIB_DIR/libmpv.dylib"
if [ -f "$LIBMPV" ]; then
    MPV_COUNT=$(ls -1 "$LIB_DIR"/*.dylib 2>/dev/null | grep -vc libgyrocore || echo 0)
    echo "==> mpv bundled: $MPV_COUNT dylibs in Resources/lib/"
    # Verify all references resolve (no external @rpath or absolute paths)
    UNRESOLVED=0
    for lib in "$LIB_DIR"/*.dylib; do
        [ "$(basename "$lib")" = "libgyrocore_c.dylib" ] && continue
        BAD=$(otool -L "$lib" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v '@loader_path' | grep -v '/usr/lib' | grep -v '/System' || true)
        if [ -n "$BAD" ]; then
            echo "  WARNING: $(basename "$lib") has external references:"
            echo "$BAD" | sed 's/^/    /'
            UNRESOLVED=1
        fi
    done
    [ "$UNRESOLVED" -eq 0 ] && echo "  All dylib references properly resolved (@loader_path)"
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
