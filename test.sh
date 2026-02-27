#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$SCRIPT_DIR/Spectrum.xcodeproj"
BUILD_DIR="$SCRIPT_DIR/build"
LOG="$BUILD_DIR/test.log"

mkdir -p "$BUILD_DIR"

# ── Parse arguments ──────────────────────────────────────────────────────────

FILTER=""          # -only-testing value (e.g. SpectrumTests/GyroConfigTests)
VERBOSE=0
CLEAN=0

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -t, --test FILTER   Run specific test (e.g. GyroConfigTests, ImageHDRDetectionTests/testDetectHDR_sdrJPEG)"
    echo "  -v, --verbose       Show full xcodebuild output"
    echo "  -c, --clean         Clean build before testing"
    echo "  -h, --help          Show this help"
    echo ""
    echo "Examples:"
    echo "  $0                          # Run all tests"
    echo "  $0 -t GyroConfigTests       # Run one test class"
    echo "  $0 -t ImageHDRDetectionTests/testDetectHDR_correctlyTaggedHLG"
    echo "  $0 -v                       # Verbose output"
    echo "  $0 -c                       # Clean + test"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--test)   FILTER="$2"; shift 2 ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -c|--clean)  CLEAN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ── Clean (optional) ─────────────────────────────────────────────────────────

if [ "$CLEAN" -eq 1 ]; then
    echo "==> Cleaning derived data..."
    xcodebuild -project "$PROJECT" -scheme Spectrum clean -quiet 2>/dev/null || true
fi

# ── Build test target ────────────────────────────────────────────────────────

ONLY_TESTING="-only-testing:SpectrumTests"
if [ -n "$FILTER" ]; then
    ONLY_TESTING="-only-testing:SpectrumTests/$FILTER"
fi

echo "==> Building & running tests..."
if [ -n "$FILTER" ]; then
    echo "    Filter: $FILTER"
fi

XCODEBUILD_CMD=(
    xcodebuild test
    -project "$PROJECT"
    -scheme Spectrum
    -destination 'platform=macOS'
    "$ONLY_TESTING"
    -derivedDataPath "$BUILD_DIR/DerivedData"
)

if [ "$VERBOSE" -eq 1 ]; then
    "${XCODEBUILD_CMD[@]}" 2>&1 | tee "$LOG"
else
    "${XCODEBUILD_CMD[@]}" 2>&1 | tee "$LOG" | grep -E "(Test Case|Test Suite|Testing |error:|warning: |\*\* TEST)" || true
fi

# ── Report ───────────────────────────────────────────────────────────────────

echo ""
if grep -q "TEST SUCCEEDED" "$LOG"; then
    PASSED=$(grep -c "^Test Case.*passed" "$LOG" 2>/dev/null || true)
    FAILED=$(grep -c "^Test Case.*failed" "$LOG" 2>/dev/null || true)
    : "${PASSED:=0}" "${FAILED:=0}"
    echo "✓ TEST SUCCEEDED — $PASSED passed, $FAILED failed"
    exit 0
else
    echo "✗ TEST FAILED"
    echo ""
    echo "Failures:"
    grep -A2 "failed\|error:" "$LOG" | head -30
    echo ""
    echo "Full log: $LOG"
    exit 1
fi
