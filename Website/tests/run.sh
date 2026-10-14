#!/bin/bash
# Runs every tests/*.test.js file with macOS JavaScriptCore (no Node needed).
# Usage: tests/run.sh            -> all test files
#        tests/run.sh grading    -> only files whose name contains "grading"
set -u
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
cd "$(dirname "$0")" || exit 1

filter="${1:-}"
total_pass=0
total_fail=0
status=0

for f in *.test.js; do
  [ -e "$f" ] || continue
  if [ -n "$filter" ] && [[ "$f" != *"$filter"* ]]; then continue; fi
  out=$("$JSC" -m "$f" 2>&1)
  code=$?
  line=$(printf '%s\n' "$out" | grep '^RESULT' | tail -1)
  if [ -z "$line" ] || [ $code -ne 0 ]; then
    printf '%s\n' "$out"
    echo "ERROR $f did not finish (exit $code)"
    status=1
    continue
  fi
  p=$(printf '%s' "$line" | sed -E 's/.*passed=([0-9]+).*/\1/')
  q=$(printf '%s' "$line" | sed -E 's/.*failed=([0-9]+).*/\1/')
  total_pass=$((total_pass + p))
  total_fail=$((total_fail + q))
  if [ "$q" != "0" ]; then
    printf '%s\n' "$out" | grep -v '^RESULT'
    echo "FAIL $f ($q failed, $p passed)"
    status=1
  else
    echo "ok   $f ($p passed)"
  fi
done

echo "TOTAL passed=$total_pass failed=$total_fail"
exit $status
