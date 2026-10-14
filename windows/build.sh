#!/bin/bash
# Builds windows/dist/Wortschatz.exe (Windows 10/11, x64) on this Mac.
# The Go compiler lives in ~/Library/Caches/Wortschatz/windows-toolchain (downloaded once from
# go.dev, not installed system-wide); the web app (index.html, src/, styles/, assets/) is embedded
# in the exe. Only windows/dist/Wortschatz.exe stays in the project.
set -euo pipefail

GO_VERSION=1.27.2
GO_SHA256=76812b213b1b2302c978d28fa52fa92d541704b9e7d9d5db8002c50e4018c4c5 # darwin-arm64

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")/Website"
TC="$HOME/Library/Caches/Wortschatz/windows-toolchain"
HOST="$HERE/host"
WEB="$HOST/webfiles/web"

if [ ! -x "$TC/go/bin/go" ]; then
  echo "Go $GO_VERSION wird heruntergeladen …"
  mkdir -p "$TC"
  curl -sSLo "$TC/go.tar.gz" "https://go.dev/dl/go${GO_VERSION}.darwin-arm64.tar.gz"
  echo "$GO_SHA256  $TC/go.tar.gz" | shasum -a 256 -c -
  tar -xzf "$TC/go.tar.gz" -C "$TC"
  rm "$TC/go.tar.gz"
fi

export GOROOT="$TC/go" GOPATH="$TC/gopath" GOMODCACHE="$TC/gopath/pkg/mod" GOCACHE="$TC/gocache"
export GOBIN="$TC/bin" GOTOOLCHAIN=local GOFLAGS=-modcacherw PATH="$TC/go/bin:$PATH"

# The web app, without macOS clutter (a temporary copy, removed again after the build).
trap 'rm -rf "$WEB" "$HOST"/rsrc_windows_*.syso' EXIT
rm -rf "$WEB"
mkdir -p "$WEB"
cp "$ROOT/index.html" "$WEB/"
cp -R "$ROOT/src" "$ROOT/styles" "$ROOT/assets" "$WEB/"
find "$WEB" -name .DS_Store -delete

cd "$HOST"
go test ./webfiles/

# Icon, version and manifest (per-monitor DPI awareness) as a Windows resource.
[ -x "$GOBIN/go-winres" ] || go install github.com/tc-hib/go-winres@v0.3.3
"$GOBIN/go-winres" make --in winres/winres.json --arch amd64 --out rsrc

GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go vet -unsafeptr=false ./... # Win32 hands structs over as uintptr
mkdir -p "$HERE/dist"
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -H windowsgui" -o "$HERE/dist/Wortschatz.exe" .
echo "Fertig: $HERE/dist/Wortschatz.exe ($(du -h "$HERE/dist/Wortschatz.exe" | cut -f1))"
