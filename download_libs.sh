#!/bin/bash
# download_libs.sh — Download pre-built dylibs and headers for Spectrum
#
# Usage:  ./download_libs.sh
#
# Downloads pre-built arm64 dylibs from GitHub Releases and extracts them to:
#   Spectrum/Resources/lib/   (dylibs)
#   mpv-build/deps/install/include/  (headers)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

REPO="chenpc/Spectrum"
TAG="deps-v1"
ASSET="spectrum-deps-arm64.tar.gz"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"

LIB_DIR="Spectrum/Resources/lib"
INCLUDE_DIR="mpv-build/deps/install/include"

# Check if libs already exist
if [ -f "$LIB_DIR/libmpv.dylib" ] && [ -f "$INCLUDE_DIR/mpv/client.h" ]; then
    echo "Dependencies already present. To re-download, remove $LIB_DIR/ first."
    exit 0
fi

echo "Downloading pre-built dependencies from GitHub..."
echo "  URL: $URL"

TMP_FILE="$(mktemp).tar.gz"
trap 'rm -f "$TMP_FILE"' EXIT

if command -v gh &>/dev/null; then
    gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --output "$TMP_FILE" --clobber
else
    curl -fSL "$URL" -o "$TMP_FILE"
fi

echo "Extracting..."
TMP_DIR="$(mktemp -d)"
tar xzf "$TMP_FILE" -C "$TMP_DIR"

# Deploy dylibs
mkdir -p "$LIB_DIR"
cp -f "$TMP_DIR"/deps/lib/*.dylib "$LIB_DIR/"
echo "  Installed $(ls -1 "$LIB_DIR"/*.dylib | wc -l | tr -d ' ') dylibs → $LIB_DIR/"

# Deploy headers
mkdir -p "$INCLUDE_DIR"
cp -Rf "$TMP_DIR"/deps/include/* "$INCLUDE_DIR/"
echo "  Installed headers → $INCLUDE_DIR/"

rm -rf "$TMP_DIR"

echo ""
echo "Done! You can now build Spectrum in Xcode."
