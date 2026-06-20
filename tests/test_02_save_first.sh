#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
today="$(date +%F)"

printf '## Summary\nDid a thing in app.ts\n' | "$RELAY" save --dir "$DIR" --digest "Did a thing"

assert_file "$DIR/history/$today.md"
assert_file "$DIR/latest.md"
assert_file "$DIR/index.md"
assert_contains "$(cat "$DIR/latest.md")" "session: 1"
assert_contains "$(cat "$DIR/latest.md")" "Did a thing in app.ts"
assert_contains "$(cat "$DIR/index.md")" "- $today — Did a thing → history/$today.md"
pass "save first session"
