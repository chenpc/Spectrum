#!/bin/bash
set -e
cd "$(dirname "$0")"

# --- Paths ---
LIB_DIR="${TESTIMG_LIB_DIR:-../MyPhoto/Spectrum/Resources/lib}"
HEADER_DIR="${TESTIMG_HEADER_DIR:-../MyPhoto/mpv-build/deps/install/include}"
PLACEBO_HEADER_DIR="/opt/homebrew/include"

# Resolve to absolute paths for -rpath
LIB_DIR_ABS="$(cd "$LIB_DIR" && pwd)"

echo "LIB_DIR:    $LIB_DIR_ABS"
echo "HEADER_DIR: $HEADER_DIR"

# --- Compile C bridges ---
echo "Compiling ffmpeg_bridge.c..."
cc -c -O2 -o ffmpeg_bridge.o ffmpeg_bridge.c \
    -I"$HEADER_DIR"

echo "Compiling placebo_bridge.c..."
cc -c -O2 -o placebo_bridge.o placebo_bridge.c \
    -I"$PLACEBO_HEADER_DIR" -DGL_SILENCE_DEPRECATION

# --- Compile and link Swift + C ---
echo "Compiling Swift + linking..."
SWIFT_FILES=(
    main.swift
    LibMPVBridge.swift
    MPVImageView.swift
    FFmpegDecode.swift
    MetalHLGView.swift
    PlaceboRender.swift
)

swiftc -O -o testimg \
    "${SWIFT_FILES[@]}" \
    ffmpeg_bridge.o placebo_bridge.o \
    -import-objc-header testimg-Bridging-Header.h \
    -framework Cocoa \
    -framework CoreGraphics \
    -framework CoreImage \
    -framework ImageIO \
    -framework OpenGL \
    -framework Metal \
    -framework MetalKit \
    -framework QuartzCore \
    "$LIB_DIR_ABS/libavformat.62.dylib" \
    "$LIB_DIR_ABS/libavcodec.62.dylib" \
    "$LIB_DIR_ABS/libswscale.9.dylib" \
    "$LIB_DIR_ABS/libavutil.60.dylib" \
    "$LIB_DIR_ABS/libplacebo.360.dylib" \
    -Xlinker -rpath -Xlinker "$LIB_DIR_ABS"

# --- Fix dylib load paths (they use @loader_path/, need @rpath/) ---
echo "Fixing dylib load paths..."
for lib in libavformat.62.dylib libavcodec.62.dylib libswscale.9.dylib libavutil.60.dylib libplacebo.360.dylib \
           libswresample.6.dylib; do
    install_name_tool -change "@loader_path/$lib" "@rpath/$lib" testimg 2>/dev/null || true
done

echo "Built: testimg"
echo "Usage: ./testimg <image_path>"
echo ""
echo "Modes 1-6: CoreGraphics/CoreImage/HLG reinterpret"
echo "Mode 7: libmpv (dlopen, no link needed)"
echo "Mode 8: FFmpeg decode + Metal HLG shader"
echo "Mode 9: libplacebo offscreen tone mapping"
