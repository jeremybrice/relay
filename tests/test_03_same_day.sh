#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
today="$(date +%F)"

printf '## Summary\nfirst\n'  | "$RELAY" save --dir "$DIR" --digest "first digest"
printf '## Summary\nsecond\n' | "$RELAY" save --dir "$DIR" --digest "second digest"

# history holds both sessions
hist="$(cat "$DIR/history/$today.md")"
assert_contains "$hist" "session: 1"
assert_contains "$hist" "session: 2"
# latest = newest
assert_contains "$(cat "$DIR/latest.md")" "second"
assert_contains "$(cat "$DIR/latest.md")" "session: 2"
# index shows the day exactly once, with the newest digest
count="$(grep -c "^- $today " "$DIR/index.md")"
assert_eq "$count" "1"
assert_contains "$(cat "$DIR/index.md")" "second digest"
pass "same-day append + index dedup"
