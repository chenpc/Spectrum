#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$SCRIPT_DIR/Spectrum.xcodeproj"
BUILD_DIR="$SCRIPT_DIR/build"
LOG="$BUILD_DIR/test.log"

mkdir -p "$BUILD_DIR"

# ── Parse arguments ──────────────────────────────────────────────────────────

FILTER=""          # -only-testing value (e.g. GyroConfigTests, ImageHDRDetectionTests/testDetectHDR_sdrJPEG)
VERBOSE=0
CLEAN=0
UI_TEST=0          # -u: run UI tests instead of unit tests

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -t, --test FILTER   Run specific test (e.g. GyroConfigTests, ImageHDRDetectionTests/testDetectHDR_sdrJPEG)"
    echo "  -u, --ui            Run UI tests (SpectrumUITests) instead of unit tests"
    echo "  -v, --verbose       Show full xcodebuild output"
    echo "  -c, --clean         Clean build before testing"
    echo "  -h, --help          Show this help"
    echo ""
    echo "Examples:"
    echo "  $0                          # Run all unit tests"
    echo "  $0 -u                       # Run all UI tests"
    echo "  $0 -u -t AppLaunchTests     # Run one UI test class"
    echo "  $0 -t GyroConfigTests       # Run one unit test class"
    echo "  $0 -t ImageHDRDetectionTests/testDetectHDR_correctlyTaggedHLG"
    echo "  $0 -v                       # Verbose output"
    echo "  $0 -c                       # Clean + test"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--test)   FILTER="$2"; shift 2 ;;
        -u|--ui)     UI_TEST=1; shift ;;
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

TEST_BUNDLE="SpectrumTests"
if [ "$UI_TEST" -eq 1 ]; then
    TEST_BUNDLE="SpectrumUITests"
fi

ONLY_TESTING="-only-testing:$TEST_BUNDLE"
if [ -n "$FILTER" ]; then
    ONLY_TESTING="-only-testing:$TEST_BUNDLE/$FILTER"
fi

if [ "$UI_TEST" -eq 1 ]; then
    echo "==> Building & running UI tests..."
else
    echo "==> Building & running tests..."
fi
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
