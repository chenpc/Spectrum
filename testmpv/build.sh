#!/bin/bash
# testmpv build script
# Usage: bash build.sh
# Then:  ./testmpv /path/to/sony-hlg.mp4

set -e
cd "$(dirname "$0")"

# ── Build libgyrocore_c.dylib (Rust) ──────────────────
WRAPPER_DIR="$(dirname "$0")/../gyro-wrapper"
echo "Building libgyrocore_c.dylib..."
if [ -d "$WRAPPER_DIR" ]; then
    (cd "$WRAPPER_DIR" && cargo build --release 2>&1 | tail -3)
    DYLIB="$WRAPPER_DIR/target/release/libgyrocore_c.dylib"
    if [ -f "$DYLIB" ]; then
        cp "$DYLIB" "$(dirname "$0")/libgyrocore_c.dylib"
        echo "  ✅ libgyrocore_c.dylib copied"
    else
        echo "  ⚠️  libgyrocore_c.dylib build failed"
    fi
else
    echo "  ⚠️  gyro-wrapper not found at $WRAPPER_DIR"
fi

echo "Building testmpv..."

MDK_HEADERS="/Applications/Gyroflow.app/Contents/Frameworks/mdk.framework/Headers/c"

swiftc main.swift \
    -import-objc-header mdk_bridge.h \
    -Xcc -DBUILD_MDK_STATIC \
    -Xcc -I"$MDK_HEADERS" \
    -framework Cocoa \
    -framework OpenGL \
    -framework QuartzCore \
    -framework AVFoundation \
    -Xlinker -rpath -Xlinker /Applications/Gyroflow.app/Contents/Frameworks \
    -Xlinker -undefined -Xlinker dynamic_lookup \
    -O \
    -o testmpv

echo ""
echo "✅ Build succeeded!"
echo ""
echo "Usage:"
echo "  ./testmpv /Users/chenpc/my_photo/C0206.MP4"
echo "  ./testmpv /Users/chenpc/my_photo/HLG.HIF"
echo "  ./testmpv   (open dialog)"
echo ""
echo "  MDK backend (Gyroflow.app)"
