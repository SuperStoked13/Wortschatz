#!/bin/bash
# Legt die Windows-App (windows-native/dist/Wortschatz.exe, native C#-App seit 1.2) als Download in
# Downloadseite/releases/ ab, zusammen mit windows.json. Der laufende Server übernimmt die neue Version innert 15 Sekunden.
#
# Aufruf (im Terminal, braucht das .NET SDK 10, läuft unter Linux, macOS und Windows):
#   Downloadseite/tools/release-windows.sh                testet und baut zuerst mit windows-native/build.sh
#   Downloadseite/tools/release-windows.sh --skip-build   die vorhandene windows-native/dist/Wortschatz.exe verwenden
#   Downloadseite/tools/release-windows.sh --version 1.2  Versionsnummer selbst setzen
#
# Die frühere Windows-App (windows/ + Website/, WebView2, bis 1.1) wird nicht mehr ausgeliefert.
set -euo pipefail

SITE="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$(cd "$SITE/.." && pwd)"
EXE="$PROJECT/windows-native/dist/Wortschatz.exe"
CSPROJ="$PROJECT/windows-native/src/Wortschatz.App/Wortschatz.App.csproj"
OUT="$SITE/releases"

BUILD=1
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) BUILD=0 ;;
    --version) VERSION="${2:-}"; shift ;;
    *) echo "Unbekannte Option: $1"; exit 1 ;;
  esac
  shift
done

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

if [[ "$BUILD" == 1 ]]; then
  "$PROJECT/windows-native/build.sh" test
fi

if [[ ! -f "$EXE" ]]; then
  echo "Keine Windows-App gefunden unter $EXE. Zuerst windows-native/build.sh ausführen."
  exit 1
fi
if [[ "$(head -c 2 "$EXE")" != "MZ" ]]; then
  echo "$EXE ist kein Windows-Programm."
  exit 1
fi

# Version aus dem Projekt (<Version>1.2.0</Version> wird zu "1.2").
if [[ -z "$VERSION" ]]; then
  VERSION=$(grep -m1 '<Version>' "$CSPROJ" 2>/dev/null | sed -E 's/.*<Version>([^<]+)<\/Version>.*/\1/' || true)
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.0$ ]] && VERSION="${VERSION%.0}"
fi
VERSION="${VERSION:-1.0}"
if [[ ! "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
  echo "Ungültige Version: $VERSION"
  exit 1
fi

NAME="Wortschatz-$VERSION-Windows.exe"
mkdir -p "$OUT"
# Erst unter einem Hilfsnamen kopieren, dann in einem Schritt umbenennen: wer gerade lädt,
# bekommt nie eine halbe Datei.
cp "$EXE" "$OUT/.$NAME.tmp"
chmod 644 "$OUT/.$NAME.tmp"
mv -f "$OUT/.$NAME.tmp" "$OUT/$NAME"

cat > "$OUT/windows.json.tmp" <<EOF
{
  "file": "$NAME",
  "version": "$VERSION",
  "released": "$(date +%Y-%m-%d)",
  "requirement": "Windows 10 oder 11",
  "architecture": "64 Bit (x64)"
}
EOF
mv -f "$OUT/windows.json.tmp" "$OUT/windows.json"

# Ältere Windows-Versionen erst jetzt entfernen, wenn das Manifest schon auf die neue zeigt.
find "$OUT" -maxdepth 1 \( -name 'Wortschatz-*-Windows.exe' -o -name 'Wortschatz-*-Windows.zip' \) ! -name "$NAME" -print -delete

# Neuigkeiten: was unter «Nächste Version» steht, gehört jetzt zu dieser Version.
python3 -I "$SITE/tools/neuigkeiten.py" "$VERSION" windows || echo "Neuigkeiten nicht eingetragen: Downloadseite/public/_neuigkeiten.md von Hand nachführen."

SIZE=$(du -h "$OUT/$NAME" | cut -f1)
echo
echo "Fertig: releases/$NAME ($SIZE)"
echo "SHA-256: $(sha256 "$OUT/$NAME")"
