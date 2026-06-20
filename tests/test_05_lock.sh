#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
mkdir -p "$DIR"

# (a) a STALE lock (dead PID) must be broken, not block forever
mkdir -p "$DIR/.lock"; printf '999999\n1\n' > "$DIR/.lock/info"   # PID unlikely alive, ts=1 (ancient)
printf '## Summary\nok\n' | "$RELAY" save --dir "$DIR" --digest "after stale"
assert_contains "$(cat "$DIR/latest.md")" "after stale"

# (b) two concurrent saves both complete, serialized (no clobbered/partial latest.md)
setup_tmp; mkdir -p "$DIR"
( printf '## Summary\nA\n' | "$RELAY" save --dir "$DIR" --digest "A" ) &
( printf '## Summary\nB\n' | "$RELAY" save --dir "$DIR" --digest "B" ) &
wait
# both sessions landed in today's history; latest.md is one intact handoff
today="$(date +%F)"
assert_eq "$(grep -c '^session:' "$DIR/history/$today.md")" "2"
assert_contains "$(cat "$DIR/latest.md")" "session:"
pass "locking"
