#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

echo "==> Cleaning build artifacts..."

# build.sh / test.sh output
if [ -d "$BUILD_DIR" ]; then
    SIZE=$(du -sh "$BUILD_DIR" | cut -f1)
    rm -rf "$BUILD_DIR"
    echo "  ✓ build/ ($SIZE)"
else
    echo "  - build/ (already clean)"
fi

# release.sh output
if [ -f "$SCRIPT_DIR/Spectrum.dmg" ]; then
    SIZE=$(du -sh "$SCRIPT_DIR/Spectrum.dmg" | cut -f1)
    rm -f "$SCRIPT_DIR/Spectrum.dmg"
    echo "  ✓ Spectrum.dmg ($SIZE)"
else
    echo "  - Spectrum.dmg (already clean)"
fi

# Rust build cache (gyro-wrapper)
TARGET_DIR="$SCRIPT_DIR/gyro-wrapper/target"
if [ -d "$TARGET_DIR" ]; then
    SIZE=$(du -sh "$TARGET_DIR" | cut -f1)
    rm -rf "$TARGET_DIR"
    echo "  ✓ gyro-wrapper/target/ ($SIZE)"
else
    echo "  - gyro-wrapper/target/ (already clean)"
fi

echo ""
echo "Done. To rebuild:"
echo "  ./build.sh     # Debug build"
echo "  ./test.sh      # Run tests"
echo "  ./release.sh   # Release build + DMG"
