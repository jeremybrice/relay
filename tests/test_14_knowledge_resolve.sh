#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
F="$DIR/knowledge/facts"

"$RELAY" knowledge add --fact --id x "original body about release.sh" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact --id x "totally different claim about auth jwt" --dir "$DIR" >/dev/null
assert_file "$F/x.conflict"

# resolve --keep new → fact body becomes the new claim; conflict cleared; loser tombstoned
out="$("$RELAY" knowledge resolve x --keep new --dir "$DIR")"
assert_contains "$out" "resolved: x"
[ -f "$F/x.conflict" ] && { echo "FAIL: conflict file should be gone"; exit 1; }
assert_contains "$(cat "$F/x.md")" "auth jwt"
assert_file "$F/superseded/x.original.md"

# resolve default (keep existing) on a second conflict
"$RELAY" knowledge add --fact --id y "keep me" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact --id y "discard this divergent one" --dir "$DIR" >/dev/null
"$RELAY" knowledge resolve y --dir "$DIR" >/dev/null
assert_contains "$(cat "$F/y.md")" "keep me"
[ -f "$F/y.conflict" ] && { echo "FAIL: conflict file should be gone"; exit 1; }
assert_file "$F/superseded/y.losing.md"   # the discarded side is tombstoned, not lost
assert_contains "$(cat "$F/superseded/y.losing.md")" "discard this divergent"
pass "knowledge resolve: keep new / keep existing, tombstone loser"
