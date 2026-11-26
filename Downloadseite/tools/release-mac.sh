#!/bin/bash
# Baut die Mac-App und legt sie als DMG in Downloadseite/releases/ ab, zusammen mit mac.json und
# appcast.xml (das Update für die installierten Apps, Sparkle). Ein lokal laufender Server zeigt die neue
# Version innert 15 Sekunden; online geht sie erst mit dem GitHub-Release (VEROEFFENTLICHEN.md).
#
# Updates: Das DMG und das appcast.xml signiert das Skript mit dem privaten Schlüssel im Schlüsselbund
# (Sparkle, Konto «wortschatz»; die App kennt die öffentliche Hälfte, mac/Wortschatz-Info.plist).
# Ohne diesen Schlüssel bricht es ab. Beim ersten Mal fragt macOS, ob sign_update ihn benutzen darf.
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
#   Downloadseite/tools/release-mac.sh --tag=v1.8     Tag des Releases (Standard v<Version>-mac); er steht im
#                                                     appcast.xml, das Release muss genau ihn haben
# Anderes Zertifikat oder anderer Zugang: MAC_SIGN_IDENTITY=… bzw. NOTARY_PROFILE=… vor den Befehl.
set -euo pipefail

SITE="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$(cd "$SITE/.." && pwd)"
APP="$PROJECT/mac/build/Wortschatz.app"
ENTITLEMENTS="$PROJECT/mac/Wortschatz/Wortschatz.entitlements"
OUT="$SITE/releases"
NOTARY_PROFILE="${NOTARY_PROFILE:-wortschatz-notary}"
# Sparkles Werkzeuge (sign_update, generate_keys) lädt Xcode mit dem Paket; mac/scripts/build.sh baut hierhin.
SPARKLE_BIN="${SPARKLE_BIN:-$HOME/Library/Caches/Wortschatz/mac-derived/SourcePackages/artifacts/sparkle/Sparkle/bin}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-wortschatz}"
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PROJECT/mac/Wortschatz-Info.plist")

BUILD_APP=1
NOTARIZE=0
TAG=""
for arg in "$@"; do
  case "$arg" in
    --skip-build) BUILD_APP=0 ;;
    --notarize) NOTARIZE=1 ;;
    --tag=?*) TAG="${arg#--tag=}" ;;
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
    echo "notarytool kommt mit dem Zugang «${NOTARY_PROFILE}» nicht zu Apple durch (fehlt er, oder kein Internet?)."
    echo "Einrichten: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple-ID> --team-id <Team-ID>"
    exit 1
  fi
fi

# Der Schlüssel muss zur App passen, sonst nimmt keine installierte App das Update an. Gibt es die
# Werkzeuge noch nicht (erster Build auf diesem Mac), prüft das Signieren unten dasselbe.
check_update_key() {
  local key
  key=$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null || true)
  if [[ "$key" != "$PUBLIC_KEY" ]]; then
    echo "Der Update-Schlüssel im Schlüsselbund (Konto «${SPARKLE_ACCOUNT}») fehlt oder passt nicht zur App."
    echo "Die App erwartet: $PUBLIC_KEY"
    echo "Gefunden: ${key:-nichts}"
    echo "Den Schlüssel hat nur Anthony (Sicherung: VEROEFFENTLICHEN.md, «Updates»)."
    exit 1
  fi
}
if [[ -x "$SPARKLE_BIN/generate_keys" ]]; then check_update_key; fi

if [[ "$BUILD_APP" == 1 ]]; then
  "$PROJECT/mac/scripts/build.sh"
fi
if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
  echo "Sparkles sign_update fehlt unter $SPARKLE_BIN (zuerst mac/scripts/build.sh, oder SPARKLE_BIN=… setzen)."
  exit 1
fi
check_update_key

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
  echo "Signieren mit «${IDENTITY_NAME}» …"
  # Zuerst Sparkles Teile, von innen nach aussen und ohne --deep (so verlangt es Sparkle): Apple
  # notarisiert nur, wenn alles darin mit Developer ID und Zeitstempel signiert ist.
  SPARKLE="$STAGED_APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/XPCServices/Installer.xpc"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Autoupdate"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Updater.app"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$STAGED_APP/Contents/Frameworks/Sparkle.framework"
  # Die Entitlements aus dem Projekt, nicht die des Builds: «Sign to Run Locally» fügt
  # get-task-allow (Debugger) hinzu, und damit lehnt Apple die Notarisierung ab. Das Projekt
  # schreibt sie mit $(PRODUCT_BUNDLE_IDENTIFIER); hier steht, was der Build daraus machte.
  RESOLVED_ENTITLEMENTS="$STAGE/Wortschatz.entitlements"
  sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")/g" \
    "$ENTITLEMENTS" > "$RESOLVED_ENTITLEMENTS"
  codesign --force --options runtime --timestamp --entitlements "$RESOLVED_ENTITLEMENTS" --sign "$IDENTITY" "$STAGED_APP"
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

# Für die installierten Apps (Sparkle): die EdDSA-Signatur des fertigen DMG (nach dem Stapeln, das
# das DMG noch ändert). Ohne sie nimmt keine App das Update an.
echo "Update signieren …"
SIGNED=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$STAGE/$NAME")
ED_SIGNATURE=$(sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' <<<"$SIGNED")
LENGTH=$(sed -nE 's/.*length="([0-9]+)".*/\1/p' <<<"$SIGNED")
if [[ -z "$ED_SIGNATURE" || -z "$LENGTH" ]]; then
  echo "sign_update hat das DMG nicht signiert: $SIGNED"
  exit 1
fi

# Neuigkeiten: was unter «Nächste Version» steht, gehört jetzt zu dieser Version (nochmals laufen
# lassen schadet nicht: dann steht dort nichts mehr für den Mac).
python3 -I "$SITE/tools/neuigkeiten.py" "$VERSION" mac || echo "Neuigkeiten nicht eingetragen: Downloadseite/public/_neuigkeiten.md von Hand nachführen."

# Das Update für die installierten Apps: appcast.xml mit den Neuigkeiten dieser Version, signiert –
# fertig, bevor etwas in releases/ kommt, damit dort nie ein altes appcast.xml neben dem neuen DMG
# liegt. Das DMG mit voller Adresse im Release: GitHub leitet um, eine relative Adresse fände Sparkle
# nicht.
TAG="${TAG:-v$VERSION-mac}"
UPDATE_REPO=$(/usr/libexec/PlistBuddy -c 'Print :WortschatzUpdateRepository' "$PLIST")
python3 -I "$SITE/tools/appcast.py" --version "$VERSION" --build "$BUILD" --min-os "$MIN_OS" \
  --url "https://github.com/$UPDATE_REPO/releases/download/$TAG/$NAME" \
  --length "$LENGTH" --signature "$ED_SIGNATURE" --out "$STAGE/appcast.xml"
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$STAGE/appcast.xml" >/dev/null
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$STAGE/appcast.xml" >/dev/null

mkdir -p "$OUT"
# Erst unter einem Hilfsnamen kopieren, dann in einem Schritt umbenennen: wer gerade lädt,
# bekommt nie eine halbe Datei.
cp "$STAGE/appcast.xml" "$OUT/.appcast.xml.tmp"
chmod 644 "$OUT/.appcast.xml.tmp"
mv -f "$OUT/.appcast.xml.tmp" "$OUT/appcast.xml"
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
if [[ "$NOTARIZE" == 1 ]]; then echo "Notarisiert: ja"; else echo "Notarisiert: nein (erster Start über «Datenschutz & Sicherheit»)"; fi
echo "SHA-256: $SUM"
echo "Update: releases/appcast.xml – mit dem DMG und mac.json an ein Release mit dem Tag «${TAG}» in $UPDATE_REPO"
echo "        hängen (anderer Tag: nochmals mit --tag=… bauen; VEROEFFENTLICHEN.md › «Updates (Mac)»)."
