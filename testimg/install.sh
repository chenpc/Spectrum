#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="testimg"
INSTALL_DIR="/usr/local/bin"

# Build release
bash build.sh

# Install
echo "Installing to $INSTALL_DIR/$APP_NAME..."
cp -f "$APP_NAME" "$INSTALL_DIR/$APP_NAME"
echo "Done. Run: testimg <image_path>"
