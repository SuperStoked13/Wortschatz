#!/bin/bash
# Baut die Mac-App und legt sie als DMG in Downloadseite/releases/ ab, zusammen mit mac.json.
# Der laufende Server übernimmt die neue Version innert 15 Sekunden von selbst.
#
# Ohne Notarisierung (Standard) muss jeder die App beim ersten Start unter «Datenschutz & Sicherheit»
# freigeben; die Downloadseite erklärt das. Mit --notarize signiert das Skript die App mit
# «Developer ID» und lässt sie von Apple notarisieren; dann fragt macOS nur einmal «Öffnen?».
# Dafür braucht es das Apple Developer Program (99 USD pro Jahr), Einrichtung in VEROEFFENTLICHEN.md.
#
# Aufruf (im Terminal, auf dem Mac):
#   Downloadseite/tools/release-mac.sh                Release-Build, dann DMG
#   Downloadseite/tools/release-mac.sh --skip-build   vorhandenes mac/build/Wortschatz.app verwenden
#   Downloadseite/tools/release-mac.sh --notarize     zusätzlich signieren und notarisieren
# Anderes Zertifikat oder anderer Zugang: MAC_SIGN_IDENTITY=… bzw. NOTARY_PROFILE=… vor den Befehl.
set -euo pipefail

SITE="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$(cd "$SITE/.." && pwd)"
APP="$PROJECT/mac/build/Wortschatz.app"
ENTITLEMENTS="$PROJECT/mac/Wortschatz/Wortschatz.entitlements"
OUT="$SITE/releases"
NOTARY_PROFILE="${NOTARY_PROFILE:-wortschatz-notary}"

BUILD_APP=1
NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) BUILD_APP=0 ;;
    --notarize) NOTARIZE=1 ;;
    *) echo "Unbekannte Option: $arg"; exit 1 ;;
  esac
done

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Dieses Skript läuft nur auf einem Mac (es braucht xcodebuild, codesign und hdiutil)."
  exit 1
fi

# Zertifikat und Zugang vor dem Bauen prüfen, damit nichts erst nach Minuten scheitert.
if [[ "$NOTARIZE" == 1 ]]; then
  if [[ -n "${MAC_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$MAC_SIGN_IDENTITY"
    IDENTITY_NAME="$MAC_SIGN_IDENTITY"
  else
    # Über die Prüfsumme statt den Namen: nach einer Verlängerung gibt es den Namen zweimal.
    line=$(security find-identity -v -p codesigning | grep -m1 '"Developer ID Application: ' || true)
    IDENTITY=$(awk '{print $2}' <<<"$line")
    IDENTITY_NAME=$(sed -E 's/.*"(.*)".*/\1/' <<<"$line")
  fi
  if [[ -z "$IDENTITY" ]]; then
    echo "Kein Zertifikat «Developer ID Application» im Schlüsselbund, darum kein --notarize möglich."
    echo "Einrichten: VEROEFFENTLICHEN.md, «Später: Mac-App notarisieren». Ohne --notarize baut das Skript wie gewohnt."
    exit 1
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "notarytool kommt mit dem Zugang «$NOTARY_PROFILE» nicht zu Apple durch (fehlt er, oder kein Internet?)."
    echo "Einrichten: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple-ID> --team-id <Team-ID>"
    exit 1
  fi
fi

if [[ "$BUILD_APP" == 1 ]]; then
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
mkdir "$STAGE/Wortschatz"
STAGED_APP="$STAGE/Wortschatz/Wortschatz.app"
ditto "$APP" "$STAGED_APP"

# Schickt eine Datei an Apple und wartet auf das Ergebnis; bei Ablehnung steht im Protokoll, warum.
notarize() {
  local result status id
  echo "Bei Apple notarisieren: $(basename "$1") (dauert meist ein paar Minuten) …"
  result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) || true
  status=$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)
  if [[ "$status" != "Accepted" ]]; then
    echo "Apple hat $(basename "$1") nicht notarisiert (Status: ${status:-unbekannt})."
    id=$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || true)
    if [[ -n "$id" ]]; then xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"; else echo "$result"; fi
    exit 1
  fi
}

if [[ "$NOTARIZE" == 1 ]]; then
  echo "Signieren mit «$IDENTITY_NAME» …"
  # Die Entitlements aus dem Projekt, nicht die des Builds: «Sign to Run Locally» fügt
  # get-task-allow (Debugger) hinzu, und damit lehnt Apple die Notarisierung ab.
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$STAGED_APP"
  codesign --verify --deep --strict "$STAGED_APP"
  signed_entitlements=$(codesign -d --entitlements - --xml "$STAGED_APP" 2>/dev/null || true)
  if [[ "$signed_entitlements" == *get-task-allow* ]]; then
    echo "Die signierte App hat noch get-task-allow; so notarisiert Apple sie nicht."
    exit 1
  fi
  # Zuerst die App selbst, damit ihr Ticket auch nach dem Kopieren nach «Programme» an ihr hängt.
  ditto -c -k --keepParent "$STAGED_APP" "$STAGE/Wortschatz.zip"
  notarize "$STAGE/Wortschatz.zip"
  xcrun stapler staple -q "$STAGED_APP"
fi

echo "DMG erstellen ($NAME) …"
ln -s /Applications "$STAGE/Wortschatz/Programme"
hdiutil create -quiet -volname "Wortschatz" -srcfolder "$STAGE/Wortschatz" -fs HFS+ -format ULFO -ov "$STAGE/$NAME"

if [[ "$NOTARIZE" == 1 ]]; then
  codesign --timestamp --sign "$IDENTITY" "$STAGE/$NAME"
  notarize "$STAGE/$NAME"
  xcrun stapler staple -q "$STAGE/$NAME"
  # So prüft Gatekeeper eine Datei aus dem Internet: beides muss «accepted» und «Notarized» melden.
  echo "Gatekeeper prüfen …"
  spctl --assess --type open --context context:primary-signature -vv "$STAGE/$NAME"
  spctl --assess --type execute -vv "$STAGED_APP"
fi
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

# Neuigkeiten: was unter «Nächste Version» steht, gehört jetzt zu dieser Version.
python3 -I "$SITE/tools/neuigkeiten.py" "$VERSION" mac || echo "Neuigkeiten nicht eingetragen: Downloadseite/public/_neuigkeiten.md von Hand nachführen."

SIZE=$(du -h "$OUT/$NAME" | cut -f1)
SUM=$(shasum -a 256 "$OUT/$NAME" | cut -d' ' -f1)
echo
echo "Fertig: releases/$NAME ($SIZE)"
if [[ "$NOTARIZE" == 1 ]]; then echo "Notarisiert: ja"; else echo "Notarisiert: nein (erster Start über «Datenschutz & Sicherheit»)"; fi
echo "SHA-256: $SUM"
