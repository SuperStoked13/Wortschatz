#!/bin/bash
# Baut die Mac-App und legt sie als DMG in Downloadseite/releases/ ab, zusammen mit mac.json.
# Der laufende Server übernimmt die neue Version innert 15 Sekunden von selbst.
#
# Aufruf (im Terminal, auf dem Mac):
#   Downloadseite/tools/release-mac.sh                Release-Build, dann DMG
#   Downloadseite/tools/release-mac.sh --skip-build   vorhandenes mac/build/Wortschatz.app verwenden
set -euo pipefail

SITE="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$(cd "$SITE/.." && pwd)"
APP="$PROJECT/mac/build/Wortschatz.app"
OUT="$SITE/releases"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Dieses Skript läuft nur auf einem Mac (es braucht xcodebuild, codesign und hdiutil)."
  exit 1
fi

if [[ "${1:-}" != "--skip-build" ]]; then
  "$PROJECT/mac/scripts/build.sh"
fi

if [[ ! -d "$APP" ]]; then
  echo "Keine App gefunden unter $APP. Zuerst mac/scripts/build.sh ausführen."
  exit 1
fi

echo "Signatur prüfen …"
codesign --verify --deep --strict "$APP"

PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST" 2>/dev/null || echo "26.0")
ARCHS=$(lipo -archs "$APP/Contents/MacOS/Wortschatz")
case "$ARCHS" in
  *arm64*x86_64* | *x86_64*arm64*) ARCH_LABEL="Apple Silicon und Intel" ;;
  *arm64*) ARCH_LABEL="Apple Silicon" ;;
  *) ARCH_LABEL="Intel" ;;
esac

NAME="Wortschatz-$VERSION-macOS.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "DMG erstellen ($NAME) …"
mkdir "$STAGE/Wortschatz"
ditto "$APP" "$STAGE/Wortschatz/Wortschatz.app"
ln -s /Applications "$STAGE/Wortschatz/Programme"
hdiutil create -quiet -volname "Wortschatz" -srcfolder "$STAGE/Wortschatz" -fs HFS+ -format ULFO -ov "$STAGE/$NAME"
hdiutil verify -quiet "$STAGE/$NAME"

mkdir -p "$OUT"
# Erst unter einem Hilfsnamen kopieren, dann in einem Schritt umbenennen: wer gerade lädt,
# bekommt nie eine halbe Datei.
cp "$STAGE/$NAME" "$OUT/.$NAME.tmp"
chmod 644 "$OUT/.$NAME.tmp"
mv -f "$OUT/.$NAME.tmp" "$OUT/$NAME"

cat > "$OUT/mac.json.tmp" <<EOF
{
  "file": "$NAME",
  "version": "$VERSION",
  "build": "$BUILD",
  "released": "$(date +%Y-%m-%d)",
  "requirement": "macOS ${MIN_OS%%.*} oder neuer",
  "architecture": "$ARCH_LABEL"
}
EOF
mv -f "$OUT/mac.json.tmp" "$OUT/mac.json"

# Ältere Mac-Versionen erst jetzt entfernen, wenn das Manifest schon auf die neue zeigt.
find "$OUT" -maxdepth 1 -name 'Wortschatz-*-macOS.dmg' ! -name "$NAME" -print -delete

SIZE=$(du -h "$OUT/$NAME" | cut -f1)
SUM=$(shasum -a 256 "$OUT/$NAME" | cut -d' ' -f1)
echo
echo "Fertig: releases/$NAME ($SIZE)"
echo "SHA-256: $SUM"
