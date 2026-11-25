#!/usr/bin/env bash
# Builds an update test of the Windows app (README › «Updates»; Mac: mac/scripts/update-test.sh): two test copies
# (9.0 and 9.1) that trust only a throwaway key and read their releases from the folder update-test next to them instead
# of GitHub (AppUpdater.TestKey). Nothing goes to GitHub, the real key is not needed, the test copies keep their own
# library in update-test/data (never the real one). Runs on Linux or macOS with the .NET 10 SDK, python3 and openssl.
#
#   windows-native/tools/update-test.sh     → windows-native/dist/update-test/ (copy the folder to a Windows PC,
#                                              then follow ANLEITUNG.txt in it)
set -euo pipefail
cd "$(dirname "$0")/.."
NATIVE=$(pwd)
SITE="$NATIVE/../Downloadseite"
OUT="$NATIVE/dist/update-test"
OLD=9.0
NEW=9.1
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/key.pem" 2>/dev/null
KEY=$(openssl pkey -in "$WORK/key.pem" -pubout -outform DER | base64 | tr -d '\n')

build() {
  echo "Testkopie $1 bauen …"
  dotnet publish src/Wortschatz.App -c Release -f net10.0-windows10.0.19041.0 -r win-x64 --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true \
    -p:DebugType=none -p:PublishReadyToRun=false -p:Version="$1.0" -p:UpdateTestKey="$KEY" -o "$WORK/publish-$1" -v q -nologo
}
build "$OLD"
build "$NEW"

rm -rf "$OUT"
mkdir -p "$OUT/update-test/v$NEW"
cp "$WORK/publish-$OLD/Wortschatz.exe" "$OUT/Wortschatz-$OLD-Windows.exe"
EXE="$OUT/update-test/v$NEW/Wortschatz-$NEW-Windows.exe"
cp "$WORK/publish-$NEW/Wortschatz.exe" "$EXE"

cat > "$WORK/neuigkeiten.md" <<NEWS
## $NEW – $(date +%Y-%m-%d)

- Neu: Update-Test: Diese Version kam von selbst, aus dem Ordner update-test.
  EN: Update test: this version came by itself, from the folder update-test.
- Verbessert: Die zweite Zeile zeigt «+1 weitere» in der Seitenleiste.
  EN: The second line shows «+1 more» in the sidebar.
NEWS
WORTSCHATZ_UPDATE_KEY="$WORK/key.pem" python3 -I "$SITE/tools/windows_update.py" schreiben --test-schluessel --version "$NEW" \
  --exe "$EXE" --neuigkeiten "$WORK/neuigkeiten.md" --out "$OUT/update-test/v$NEW/windows-update.json"

# The release list as GitHub would give it, with addresses relative to itself.
python3 -I - "$OUT/update-test" "$NEW" <<'PY'
import json, os, sys
folder, version = sys.argv[1], sys.argv[2]
assets = []
for name in ('windows-update.json', f'Wortschatz-{version}-Windows.exe'):
    assets.append({'name': name, 'size': os.path.getsize(os.path.join(folder, f'v{version}', name)),
                   'browser_download_url': f'v{version}/{name}'})
release = {'tag_name': f'v{version}-test', 'draft': False, 'prerelease': False,
           'published_at': '2026-11-25T12:00:00Z', 'assets': assets}
with open(os.path.join(folder, 'releases.json'), 'w', encoding='utf-8') as handle:
    json.dump([release], handle, indent=2)
PY

cat > "$OUT/ANLEITUNG.txt" <<TXT
Update-Test der Windows-App (Wortschatz $OLD → $NEW, nur Testkopien)

Die Testkopien vertrauen nur einem Wegwerf-Schlüssel, lesen ihre «Releases» aus dem Ordner update-test statt von GitHub
und haben ihre eigene Bibliothek in update-test\\data (deine echten Lernsets bleiben unberührt).

1. Den ganzen Ordner auf den Windows-PC kopieren, zum Beispiel auf den Schreibtisch (nicht nach «Programme»).
2. Wortschatz-$OLD-Windows.exe starten (SmartScreen: «Weitere Informationen» › «Trotzdem ausführen»).
3. Einstellungen › Daten › Updates › «Jetzt suchen». Erwartet: «Version $NEW ist bereit» mit zwei Neuigkeiten → «Später».
   (Ohne Klick sucht die App etwa 20 Sekunden nach dem Start von selbst.)
4. Das Fenster schliessen. Erwartet: Wortschatz-$OLD-Windows.exe ist jetzt Version $NEW (Rechtsklick › Eigenschaften ›
   Details), daneben liegt versteckt Wortschatz-$OLD-Windows.exe.old.
5. Wieder starten: ohne SmartScreen-Frage; unten in der Seitenleiste «Aktualisiert auf $NEW» mit der ersten Neuigkeit
   und «+1 weitere» (Klick: beide); die .old ist weg. Einstellungen › Daten › Info › Version: $NEW.
6. Nochmals: Ordner neu kopieren, in Schritt 3 «Jetzt neu starten» wählen → das Fenster geht zu, $NEW startet gleich.
TXT

echo "→ windows-native/dist/update-test/ ($(du -sh "$OUT" | cut -f1)) – auf einen Windows-PC kopieren, dann ANLEITUNG.txt"
