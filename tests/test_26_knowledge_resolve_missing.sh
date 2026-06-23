#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

"$RELAY" knowledge add --fact --id g "original body about make" --dir "$DIR" >/dev/null
# orphan conflict: pending conflict but the fact .md is gone
printf 'a different body entirely\n' > "$DIR/knowledge/facts/g.conflict"
rm -f "$DIR/knowledge/facts/g.md"

rc=0; out="$("$RELAY" knowledge resolve --keep new g --dir "$DIR" 2>&1)" || rc=$?
assert_eq "$rc" "0"
assert_contains "$out" "resolved: g"
assert_file "$DIR/knowledge/facts/g.md"
assert_contains "$(cat "$DIR/knowledge/facts/g.md")" "a different body entirely"
[ -e "$DIR/knowledge/facts/g.conflict" ] && { echo "FAIL: conflict left pending"; exit 1; } || true

pass "knowledge resolve: --keep new recreates fact and clears conflict when .md is missing"
