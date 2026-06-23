#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
INSTR="$TMP/CLAUDE.md"; export RELAY_INSTRUCTION_FILE="$INSTR"
L="$DIR/knowledge/lessons"

"$RELAY" knowledge add --lesson --id types-first "Regen types first." --dir "$DIR" >/dev/null
"$RELAY" knowledge graduate types-first --dir "$DIR" >/dev/null
assert_contains "$(cat "$INSTR")" "<!-- relay:learned:types-first -->"

# ungraduate removes the block lines (idempotent) and tombstones the lesson
out="$("$RELAY" knowledge ungraduate types-first --dir "$DIR")"
assert_contains "$out" "ungraduated: types-first"
[ "$(grep -cF "<!-- relay:learned:types-first -->" "$INSTR")" = "0" ] || { echo "FAIL: block not removed"; exit 1; }
assert_file "$L/superseded/types-first.md"
# idempotent second call
"$RELAY" knowledge ungraduate types-first --dir "$DIR" >/dev/null 2>&1 || true
assert_eq "$(grep -cF "<!-- relay:learned:types-first -->" "$INSTR")" "0"

# supersede an active fact
"$RELAY" knowledge add --fact --id pin-dep "pin dep to 4.1 for now" --dir "$DIR" >/dev/null
"$RELAY" knowledge supersede pin-dep --dir "$DIR" >/dev/null
assert_file "$DIR/knowledge/facts/superseded/pin-dep.md"
[ -f "$DIR/knowledge/facts/pin-dep.md" ] && { echo "FAIL: fact should be tombstoned"; exit 1; }
pass "knowledge ungraduate + supersede"
