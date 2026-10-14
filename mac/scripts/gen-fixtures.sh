#!/bin/bash
# Regenerates the parity fixtures from the web reference implementation.
#
# Runs every mac/Parity/gen-<name>.js with JavaScriptCore (no Node needed) under
# TZ=Europe/Zurich and writes its JSON output to
# mac/Packages/WortschatzCore/Tests/WortschatzCoreTests/Fixtures/<name>.json.
# New generators are picked up automatically.
#
# Usage: mac/scripts/gen-fixtures.sh            -> all generators
#        mac/scripts/gen-fixtures.sh text time  -> only gen-text.js and gen-time.js
set -euo pipefail

JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PARITY_DIR="$MAC_DIR/Parity"
OUT_DIR="$MAC_DIR/Packages/WortschatzCore/Tests/WortschatzCoreTests/Fixtures"

export TZ=Europe/Zurich
mkdir -p "$OUT_DIR"

TMP_DIR="$(mktemp -d -t wortschatz-parity)"
trap 'rm -rf "$TMP_DIR"' EXIT

status=0
found=0
for gen in "$PARITY_DIR"/gen-*.js; do
  [ -e "$gen" ] || continue
  name="$(basename "$gen" .js)"
  name="${name#gen-}"
  if [ $# -gt 0 ]; then
    wanted=0
    for arg in "$@"; do [ "$arg" = "$name" ] && wanted=1; done
    [ $wanted -eq 1 ] || continue
  fi
  found=$((found + 1))
  out="$TMP_DIR/$name.json"
  if ! "$JSC" -m "$gen" > "$out" 2> "$TMP_DIR/$name.err"; then
    echo "FAIL $name: generator exited with an error"
    cat "$out" "$TMP_DIR/$name.err" | tail -20
    status=1
    continue
  fi
  # Validate: one JSON document with a non-empty "cases" array.
  if ! check="$("$JSC" -e "const d = JSON.parse(readFile('$out')); if (!Array.isArray(d.cases) || d.cases.length !== d.count || !d.count) throw new Error('bad fixture'); print(d.count);" 2>&1)"; then
    echo "FAIL $name: output is not a valid fixture"
    echo "$check" | tail -5
    head -c 400 "$out"
    status=1
    continue
  fi
  cp "$out" "$OUT_DIR/$name.json"
  printf 'ok   %-12s %6s cases  %8s bytes\n' "$name" "$check" "$(wc -c < "$out" | tr -d ' ')"
done

if [ $found -eq 0 ]; then
  echo "No generator matched: $*"
  exit 1
fi
exit $status
