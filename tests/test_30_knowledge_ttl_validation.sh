#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

# non-integer ttl rejected (exit 2), nothing written
assert_exit 2 "$RELAY" knowledge add --fact --id t1 --ttl 30d "body about a thing" --dir "$DIR"
assert_exit 2 "$RELAY" knowledge add --fact --id t2 --ttl abc "body about a thing" --dir "$DIR"
[ -e "$DIR/knowledge/facts/t1.md" ] && { echo "FAIL: t1 written despite bad ttl"; exit 1; } || true

# valid ttls still accepted: integer and the literal 'none'
"$RELAY" knowledge add --fact --id t3 --ttl 30   "body three about a thing" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact --id t4 --ttl none "body four about a thing" --dir "$DIR" >/dev/null
assert_file "$DIR/knowledge/facts/t3.md"
assert_file "$DIR/knowledge/facts/t4.md"

# load with the valid-ttl fact present emits no integer-expression noise
printf '## S\nbody\n' | "$RELAY" save --dir "$DIR" --digest d
err="$("$RELAY" load --dir "$DIR" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q 'integer expression' && { echo "FAIL: load leaked: $err"; exit 1; } || true

pass "knowledge ttl validation: non-integer rejected, integer/none accepted, no load noise"
