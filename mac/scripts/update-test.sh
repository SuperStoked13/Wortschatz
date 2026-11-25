#!/bin/bash
# A whole update of the Mac app (Sparkle) without GitHub and without the real key: builds two Release
# test copies (9.0 and 9.1, bundle id app.wortschatz.mac.updatetest, so they never touch the real
# library), signs 9.1 like Downloadseite/tools/release-mac.sh does but with a throwaway key, and serves
# it on 127.0.0.1 the way GitHub does (a release list; every release file redirects to a signed address
# elsewhere). Installs 9.0 as /Applications/Wortschatz Updatetest.app, starts it, lets Sparkle load the
# update, quits it and checks that 9.1 is installed, not quarantined, starts without asking GitHub
# (no check is due), and shows «Aktualisiert auf 9.1» with the Mac entries of the test Neuigkeiten.
#
# The test copy's window shows briefly on screen. Its data folder
# (~/Library/Containers/app.wortschatz.mac.updatetest) stays: macOS does not let scripts remove it.
#
# Usage: mac/scripts/update-test.sh
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SITE="$MAC_DIR/../Downloadseite"
DERIVED="$HOME/Library/Caches/Wortschatz/update-test-derived"
BUNDLE_ID=app.wortschatz.mac.updatetest
INSTALLED="/Applications/Wortschatz Updatetest.app"
PORT=8765
WORK=$(mktemp -d)
SERVER_PID=""
cleanup() {
  pkill -TERM -f "$INSTALLED/Contents/MacOS/Wortschatz" 2>/dev/null || true
  if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  sleep 1
  rm -rf "$INSTALLED" "$HOME/Library/Caches/$BUNDLE_ID" "$WORK"
}
fail() { echo "FAILED: $*"; exit 1; }

if [[ -e "$INSTALLED" ]]; then fail "$INSTALLED exists already (an earlier test?); remove it first."; fi
trap cleanup EXIT
# A fresh start: Sparkle checks at once only if it never checked or the last check is a day old.
defaults delete "$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Preferences/$BUNDLE_ID" >/dev/null 2>&1 || true

echo "== Throwaway signing key"
cat > "$WORK/testkey.swift" <<'EOF'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
EOF
PUB=$(swift "$WORK/testkey.swift" "$WORK/key.txt")
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"

echo "== Two Release test copies (9.0, 9.1)"
cd "$MAC_DIR"
for spec in "9.0 900 old" "9.1 901 new"; do
  read -r version build name <<<"$spec"
  xcodebuild -project Wortschatz.xcodeproj -scheme Wortschatz -configuration Release -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    build > "$WORK/build-$name.log" 2>&1 || fail "build $version (log: $WORK/build-$name.log)"
  APP="$WORK/$name/Wortschatz.app"
  mkdir -p "$WORK/$name"
  ditto "$DERIVED/Build/Products/Release/Wortschatz.app" "$APP"
  # The test key and the local release list instead of GitHub; re-signed with the build's entitlements.
  codesign -d --entitlements - --xml "$APP" > "$WORK/$name.entitlements" 2>/dev/null
  P="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUB" \
    -c "Add :WortschatzUpdateReleasesURL string http://127.0.0.1:$PORT/releases.json" \
    -c "Add :NSAppTransportSecurity dict" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$P"
  codesign --force --sign - --options runtime --entitlements "$WORK/$name.entitlements" "$APP" 2>/dev/null
  codesign --verify --deep --strict "$APP"
done

echo "== Release 9.1 like release-mac.sh (DMG, appcast.py, signatures)"
WWW="$WORK/www"
mkdir -p "$WWW/download/v9.1-mac" "$WORK/dmg/Wortschatz"
NAME="Wortschatz-9.1-macOS.dmg"
ditto "$WORK/new/Wortschatz.app" "$WORK/dmg/Wortschatz/Wortschatz.app"
ln -s /Applications "$WORK/dmg/Wortschatz/Programme"
hdiutil create -quiet -volname Wortschatz -srcfolder "$WORK/dmg/Wortschatz" -fs HFS+ -format ULFO -ov "$WWW/download/v9.1-mac/$NAME"
SIGNED=$("$SPARKLE_BIN/sign_update" --ed-key-file "$WORK/key.txt" "$WWW/download/v9.1-mac/$NAME")
cat > "$WORK/neuigkeiten.md" <<'EOF'
## 9.1 – 2026-11-25

- Neu (Mac): Erster Testeintrag nur für den Mac.
  EN: First test entry, Mac only.
- Behoben (Windows): Nur Windows, darf im Mac-Update fehlen.
  EN: Windows only.
- Verbessert: Zweiter Testeintrag für beide Apps.
  EN: Second test entry for both apps.
EOF
U="http://127.0.0.1:$PORT/download"
python3 -I "$SITE/tools/appcast.py" --version 9.1 --build 901 --min-os 26.0 --url "$U/v9.1-mac/$NAME" \
  --length "$(sed -nE 's/.*length="([0-9]+)".*/\1/p' <<<"$SIGNED")" \
  --signature "$(sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' <<<"$SIGNED")" \
  --neuigkeiten "$WORK/neuigkeiten.md" --out "$WWW/download/v9.1-mac/appcast.xml"
"$SPARKLE_BIN/sign_update" --ed-key-file "$WORK/key.txt" "$WWW/download/v9.1-mac/appcast.xml" >/dev/null
# Newest first: a Windows-only release and a Mac pre-release that must both be passed over.
cat > "$WWW/releases.json" <<EOF
[
  {"tag_name": "v9.2", "draft": false, "prerelease": false, "published_at": "2026-11-25T12:00:00Z",
   "assets": [{"name": "windows.json", "browser_download_url": "$U/v9.2/windows.json"}]},
  {"tag_name": "v9.9-mac", "draft": false, "prerelease": true, "published_at": "2026-11-25T13:00:00Z",
   "assets": [{"name": "appcast.xml", "browser_download_url": "$U/v9.9-mac/appcast.xml"}]},
  {"tag_name": "v9.1-mac", "draft": false, "prerelease": false, "published_at": "2026-11-25T11:00:00Z",
   "assets": [{"name": "$NAME", "browser_download_url": "$U/v9.1-mac/$NAME"},
              {"name": "appcast.xml", "browser_download_url": "$U/v9.1-mac/appcast.xml"}]}
]
EOF
# Like GitHub: /download/<tag>/<file> answers 302 to /assets/<id>?sig=…, so an address relative to
# the appcast would point at /assets/… and fail; the file itself names itself in Content-Disposition.
cat > "$WORK/server.py" <<'SERVER'
import http.server, os, sys, uuid
root, port, assets = sys.argv[1], int(sys.argv[2]), {}
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/releases.json':
            return self.send_file(os.path.join(root, 'releases.json'))
        if path.startswith('/download/') and os.path.isfile(os.path.join(root, path.lstrip('/'))):
            key = uuid.uuid4().hex
            assets[key] = os.path.join(root, path.lstrip('/'))
            self.send_response(302)
            self.send_header('Location', f'/assets/{key}?sig=test')
            self.send_header('Content-Length', '0')
            return self.end_headers()
        if path.startswith('/assets/') and path[len('/assets/'):] in assets:
            return self.send_file(assets[path[len('/assets/'):]], attachment=True)
        self.send_error(404)
    def send_file(self, file, attachment=False):
        data = open(file, 'rb').read()
        self.send_response(200)
        if attachment:
            self.send_header('Content-Disposition', f'attachment; filename={os.path.basename(file)}')
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
SERVER
python3 -I "$WORK/server.py" "$WWW" "$PORT" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
sleep 1

echo "== 9.0 installed and started; waiting for Sparkle to load 9.1"
ditto "$WORK/old/Wortschatz.app" "$INSTALLED"
open "$INSTALLED"
for _ in $(seq 1 90); do
  grep -q "GET /download/v9.1-mac/$NAME" "$WORK/server.log" && break
  sleep 1
done
grep -q "GET /download/v9.1-mac/$NAME" "$WORK/server.log" || fail "no download of the update (server log: $(cat "$WORK/server.log"))"
sleep 5

echo "== Quitting; Sparkle installs"
pkill -TERM -f "$INSTALLED/Contents/MacOS/Wortschatz"
for _ in $(seq 1 60); do
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED/Contents/Info.plist" 2>/dev/null)" == 901 ]] && break
  sleep 1
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED/Contents/Info.plist")" == 901 ]] || fail "9.1 was not installed"
codesign --verify --deep --strict "$INSTALLED" || fail "the installed update has a broken signature"
if xattr -p com.apple.quarantine "$INSTALLED" >/dev/null 2>&1; then fail "the update is quarantined (Gatekeeper would ask again)"; fi

grep -qE 'GET /assets/[0-9a-f]+\?sig=test HTTP/1.1" 200' "$WORK/server.log" || fail "the update did not come through the redirect"

echo "== 9.1 starts, without asking GitHub (no check is due), and has the notice"
LOOKUPS=$(grep -c "GET /releases.json" "$WORK/server.log")
open "$INSTALLED"
sleep 10
pgrep -f "$INSTALLED/Contents/MacOS/Wortschatz" >/dev/null || fail "9.1 does not start"
[[ "$(grep -c "GET /releases.json" "$WORK/server.log")" == "$LOOKUPS" ]] || fail "9.1 asked GitHub at launch although no check was due"
python3 -I - "$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Preferences/$BUNDLE_ID.plist" <<'EOF' || fail "no notice for 9.1"
import json, plistlib, sys
notice = json.loads(plistlib.load(open(sys.argv[1], 'rb'))['update.notice'])
assert notice['version'] == '9.1' and len(notice['changes']) == 2, notice
assert not any('Windows' in change for change in notice['changes']), notice
print('notice:', notice['changes'])
EOF
echo "OK: 9.0 updated itself to 9.1."
