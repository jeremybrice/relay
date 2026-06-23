#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
INSTR="$TMP/CLAUDE.md"; export RELAY_INSTRUCTION_FILE="$INSTR"
L="$DIR/knowledge/lessons"

"$RELAY" knowledge add --lesson --id types-first "Regenerate types before call-sites." --dir "$DIR" >/dev/null

# case 1: no region yet → graduate creates region + id-block, moves the lesson
out="$("$RELAY" knowledge graduate types-first --dir "$DIR")"
assert_contains "$out" "graduated: types-first"
assert_contains "$(cat "$INSTR")" "<!-- relay:learned -->"
assert_contains "$(cat "$INSTR")" "<!-- relay:learned:types-first -->"
assert_contains "$(cat "$INSTR")" "Regenerate types before call-sites."
assert_file "$L/graduated/types-first.md"
[ -f "$L/types-first.md" ] && { echo "FAIL: active lesson should have moved"; exit 1; }
assert_contains "$(cat "$L/graduated/types-first.md")" "status: graduated"

# case 2: idempotent — re-running graduate on a graduated id does not duplicate the block
"$RELAY" knowledge graduate types-first --dir "$DIR" >/dev/null 2>&1 || true
count="$(grep -cF "<!-- relay:learned:types-first -->" "$INSTR")"
assert_eq "$count" "1"

# case 3: a SECOND lesson graduates into the SAME region (not a second region)
"$RELAY" knowledge add --lesson --id lint-first "Run the linter before committing." --dir "$DIR" >/dev/null
"$RELAY" knowledge graduate lint-first --dir "$DIR" >/dev/null
assert_eq "$(grep -cF "<!-- relay:learned -->" "$INSTR")" "1"
assert_contains "$(cat "$INSTR")" "<!-- relay:learned:lint-first -->"

# case 4: user hand-edits prose after the region, THEN a new lesson graduates →
# region stays single, the new block lands, hand-written prose survives.
printf '\n## My own notes\nhand-written.\n' >> "$INSTR"
"$RELAY" knowledge add --lesson --id lint-after "Run lints after the edit." --dir "$DIR" >/dev/null
"$RELAY" knowledge graduate lint-after --dir "$DIR" >/dev/null
assert_contains "$(cat "$INSTR")" "<!-- relay:learned:types-first -->"
assert_contains "$(cat "$INSTR")" "<!-- relay:learned:lint-after -->"
assert_contains "$(cat "$INSTR")" "hand-written."
assert_eq "$(grep -cF "<!-- relay:learned -->" "$INSTR")" "1"

# case 5: a MULTI-LINE lesson body graduates intact (regression guard — newline must not break the awk block write)
"$RELAY" knowledge add --lesson --id multi "First line of the lesson.
Second line with the why." --dir "$DIR" >/dev/null
"$RELAY" knowledge graduate multi --dir "$DIR" >/dev/null
assert_contains "$(cat "$INSTR")" "First line of the lesson."
assert_contains "$(cat "$INSTR")" "Second line with the why."

# case 6: instruction file has a region-OPEN with NO matching CLOSE (hand-corruption).
# graduate must STILL emit the id-block (no silent drop) and repair the region.
INSTR2="$TMP/CLAUDE2.md"
printf 'preamble\n<!-- relay:learned -->\n' > "$INSTR2"   # orphan open, no close, no rend anywhere
"$RELAY" knowledge add --lesson --id orphan "Orphan-region lesson body." --dir "$DIR" >/dev/null
RELAY_INSTRUCTION_FILE="$INSTR2" "$RELAY" knowledge graduate orphan --dir "$DIR" >/dev/null
assert_contains "$(cat "$INSTR2")" "<!-- relay:learned:orphan -->"
assert_contains "$(cat "$INSTR2")" "Orphan-region lesson body."
assert_contains "$(cat "$INSTR2")" "<!-- /relay:learned -->"   # region-close emitted/repaired

pass "knowledge graduate: region create, idempotent, shared region, hand-edit safe, multi-line body, orphan-region repair"
