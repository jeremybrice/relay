#!/usr/bin/env bash
# tests/run.sh — run every test_*.sh; print failures with their output; exit 1 if any failed.
set -uo pipefail
cd "$(dirname "$0")"
fail=0 n=0
for t in test_*.sh; do
  n=$((n + 1))
  if out="$(bash "$t" 2>&1)"; then
    printf '%s\n' "$out"
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n%s\n' "$t" "$out" | sed 's/^/  /'
  fi
done
echo "---"
echo "$((n - fail))/$n test files passed"
[ "$fail" -eq 0 ]
