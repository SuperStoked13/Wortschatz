#!/bin/bash
# Runs the WortschatzCore package tests (unit + parity), compiles the app with its unit and UI
# tests, and runs the app's unit tests (WortschatzTests, hosted in the DEBUG app on an in-memory
# library).
# Usage: mac/scripts/test.sh          -> swift test + build-for-testing + app unit tests
#        mac/scripts/test.sh --ui     -> additionally runs the UI tests (needs a logged-in GUI
#                                        session; macOS asks for automation permission)
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Build products and logs live outside the project, in ~/Library/Caches/Wortschatz.
CACHE="$HOME/Library/Caches/Wortschatz"
DERIVED="$CACHE/mac-derived"
mkdir -p "$CACHE/logs"
RUN_UI=0
[ "${1:-}" = "--ui" ] && RUN_UI=1

echo "== swift test (WortschatzCore)"
(cd "$MAC_DIR/Packages/WortschatzCore" && swift test --scratch-path "$CACHE/mac-swiftpm" 2>&1 | grep -vE '^\[[0-9]+/[0-9]+\]|^◇ |^✔ Test (".*"|[A-Za-z0-9_]+\(\)) passed' )
# (grep only trims the progress lines; `pipefail` keeps swift test's exit status)

cd "$MAC_DIR"
LOG="$CACHE/logs/xcodebuild-test.log"
echo "== xcodebuild build-for-testing (Wortschatz + WortschatzUITests)"
if ! xcodebuild \
  -project Wortschatz.xcodeproj \
  -scheme Wortschatz \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build-for-testing > "$LOG" 2>&1; then
  grep -E "error:|\*\* .* \*\*" "$LOG" | head -40 || true
  echo "build-for-testing failed. Full log: $LOG"
  exit 1
fi
grep -E "^/.*/mac/(Wortschatz|WortschatzUITests|Packages)/.*: warning:" "$LOG" | sort -u || true
echo "build-for-testing OK"

echo "== xcodebuild test-without-building (WortschatzTests: app unit tests)"
UNIT_LOG="$CACHE/logs/xcodebuild-unittest.log"
if ! xcodebuild \
  -project Wortschatz.xcodeproj \
  -scheme Wortschatz \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:WortschatzTests \
  test-without-building > "$UNIT_LOG" 2>&1; then
  grep -E "✘|error:|\*\* .* \*\*" "$UNIT_LOG" | head -40 || true
  echo "App unit tests failed. Full log: $UNIT_LOG"
  exit 1
fi
grep -E "^✔ Test run|^✘ Test run" "$UNIT_LOG" || true

if [ $RUN_UI -eq 1 ]; then
  echo "== xcodebuild test-without-building (UI tests)"
  xcodebuild \
    -project Wortschatz.xcodeproj \
    -scheme Wortschatz \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:WortschatzUITests \
    test-without-building
fi
echo "All tests OK"
