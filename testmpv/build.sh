#!/bin/bash
# testmpv build script — AVFoundation + Metal + Gyro video player
# Usage: bash build.sh
# Then:  ./testmpv /path/to/sony-hlg.mp4

set -e
cd "$(dirname "$0")"

echo "Building testmpv..."

swiftc main.swift \
    -framework Cocoa \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework Metal \
    -framework QuartzCore \
    -O \
    -o testmpv

echo ""
echo "Build succeeded!"
echo ""
echo "Usage:"
echo "  ./testmpv /Users/chenpc/my_photo/C0206.MP4"
echo "  ./testmpv   (open dialog)"
