#!/bin/bash
# testmpv build script
# Usage: bash build.sh
# Then:  ./testmpv /path/to/sony-hlg.mp4

set -e
cd "$(dirname "$0")"

# ── Build libgyrocore_c.dylib (Rust) ──────────────────
GYRO_DIR="$HOME/gyroflow"
PLAYER_DIR="$GYRO_DIR/player"
echo "Building libgyrocore_c.dylib..."
if [ -d "$PLAYER_DIR" ]; then
    (cd "$PLAYER_DIR" && cargo build --release --lib 2>&1 | tail -3)
    # workspace 層級 target 目錄
    if [ -f "$GYRO_DIR/target/release/libgyrocore_c.dylib" ]; then
        cp "$GYRO_DIR/target/release/libgyrocore_c.dylib" "$(dirname "$0")/libgyrocore_c.dylib"
        echo "  ✅ libgyrocore_c.dylib copied"
    else
        echo "  ⚠️  libgyrocore_c.dylib build failed"
    fi
fi

echo "Building testmpv..."

swiftc main.swift \
    -framework Cocoa \
    -framework OpenGL \
    -framework QuartzCore \
    -framework AVFoundation \
    -Xlinker -rpath -Xlinker /Applications/IINA.app/Contents/Frameworks \
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
echo "mpv log: /tmp/testmpv.log"
