#!/usr/bin/env bash
# Builds the native Windows app as one Wortschatz.exe (self-contained: no .NET installation needed on the PC).
# Runs on Linux, macOS or Windows with the .NET 10 SDK. Output: windows-native/dist/Wortschatz.exe
#   ./build.sh            → dist/Wortschatz.exe (x64)
#   ./build.sh arm64      → dist/Wortschatz-arm64.exe (Windows on ARM)
#   ./build.sh test       → runs the core tests first
set -euo pipefail
cd "$(dirname "$0")"
arch="x64"
for a in "$@"; do
  case "$a" in
    arm64) arch="arm64" ;;
    test) dotnet test tests/Wortschatz.Core.Tests ;;
  esac
done
out="dist/publish-$arch"
# ReadyToRun per assembly, not one composite image: by default a single file with ReadyToRun precompiles the whole .NET
# runtime with the app into one block (132 MB unpacked) that the exe unpacks into memory at every start, also the many
# parts the app never uses. Per assembly only what is loaded gets unpacked: the same start time on Joan's laptop,
# about 90 MB less memory, a 15 MB smaller exe (25.11.2026).
dotnet publish src/Wortschatz.App -c Release -f net10.0-windows10.0.19041.0 -r "win-$arch" --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true \
  -p:DebugType=none -p:PublishReadyToRun=true -p:PublishReadyToRunComposite=false -o "$out"
name="Wortschatz.exe"
[ "$arch" = "arm64" ] && name="Wortschatz-arm64.exe"
mkdir -p dist
cp "$out/Wortschatz.exe" "dist/$name"
echo "→ windows-native/dist/$name ($(du -h "dist/$name" | cut -f1))"
