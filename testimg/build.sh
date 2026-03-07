#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Compiling testimg (Apple-native only)..."
swiftc -O -o testimg \
    main.swift \
    MetalHLGView.swift \
    -framework Cocoa \
    -framework CoreGraphics \
    -framework ImageIO \
    -framework Metal \
    -framework QuartzCore

echo "Built: testimg"
echo "Usage: ./testimg <image_path>"
echo ""
echo "Modes 1-6: CoreGraphics/CoreImage/HLG reinterpret"
echo "Mode 7: Metal HLG shader (Apple-native decode)"
