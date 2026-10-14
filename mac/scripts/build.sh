#!/bin/bash
# Release build of the Mac app into mac/build/Wortschatz.app (non-interactive, ad-hoc signed).
# Derived data and logs live outside the project, in ~/Library/Caches/Wortschatz.
# Usage: mac/scripts/build.sh
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$HOME/Library/Caches/Wortschatz"
DERIVED="$CACHE/mac-derived"
cd "$MAC_DIR"
mkdir -p build "$CACHE/logs"
LOG="$CACHE/logs/xcodebuild-release.log"

echo "Building Wortschatz (Release)…"
if ! xcodebuild \
  -project Wortschatz.xcodeproj \
  -scheme Wortschatz \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build > "$LOG" 2>&1; then
  grep -E "error:|\*\* BUILD" "$LOG" | head -40 || true
  echo "Build failed. Full log: $LOG"
  exit 1
fi

# Warnings in our own sources (app, UI tests, package).
warnings=$(grep -E "^/.*/mac/(Wortschatz|WortschatzUITests|Packages)/.*: warning:" "$LOG" | sort -u || true)
if [ -n "$warnings" ]; then
  echo "$warnings"
  echo "WARNING: $(printf '%s\n' "$warnings" | wc -l | tr -d ' ') warning(s) in our code (see above)."
fi

rm -rf build/Wortschatz.app
ditto "$DERIVED/Build/Products/Release/Wortschatz.app" build/Wortschatz.app
codesign --verify --deep --strict build/Wortschatz.app
echo "OK: $MAC_DIR/build/Wortschatz.app"
