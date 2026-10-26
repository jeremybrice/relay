#!/usr/bin/env bash
# test_51_graduate_rule.sh: graduate --rule writes one short line (not the lesson body) into the
# instruction file, verbatim even for shell-hostile text; bad rules are refused; why finds
# graduated lessons.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
INSTR="$TMP/AGENTS.md"; export RELAY_INSTRUCTION_FILE="$INSTR"; : > "$INSTR"
L="$DIR/knowledge/lessons"
add() { "$RELAY" knowledge add --lesson --id "$1" "$2" --dir "$DIR" >/dev/null; }

add x "When a long script is running, never edit it in place, because bash reads it lazily (2026-10-15 incident)."
out="$("$RELAY" knowledge graduate x --rule "Never edit a running script." --dir "$DIR")"
assert_contains "$out" "graduated: x"
assert_eq "$(sed -n '/^<!-- relay:learned:x -->$/,/^<!-- \/relay:learned:x -->$/p' "$INSTR")" "<!-- relay:learned:x -->
- Never edit a running script. (why: relay knowledge why x)
<!-- /relay:learned:x -->"
[ -z "$(grep -F 'bash reads it lazily' "$INSTR" || true)" ] || { echo "FAIL: lesson body copied into the rule"; exit 1; }
assert_contains "$(cat "$L/graduated/x.md")" "rule: Never edit a running script."

# graduate --rule writes shell-hostile text verbatim
add y "body y"
"$RELAY" knowledge graduate y --rule - --dir "$DIR" >/dev/null <<'R'
Use "$(pwd)" & `git` 'carefully'
R
assert_contains "$(cat "$INSTR")" "- Use \"\$(pwd)\" & \`git\` 'carefully' (why: relay knowledge why y)"

# refused: two lines, empty, 241 characters; lesson stays active, file unchanged
add bad "body bad"
before="$(cat "$INSTR")"
long="$(printf 'a%.0s' $(seq 1 241))"
for r in "$(printf 'one\ntwo')" "" "$long"; do
  err="$("$RELAY" knowledge graduate bad --rule "$r" --dir "$DIR" 2>&1)" && { echo "FAIL: bad rule accepted"; exit 1; }
  assert_contains "$err" "relay: --rule must be one line of 1 to 240 characters"
  assert_exit 2 "$RELAY" knowledge graduate bad --rule "$r" --dir "$DIR"
done
assert_file "$L/bad.md"
assert_eq "$(cat "$INSTR")" "$before"
ok240="$(printf 'b%.0s' $(seq 1 240))"
"$RELAY" knowledge graduate bad --rule "$ok240" --dir "$DIR" >/dev/null
assert_contains "$(cat "$INSTR")" "- $ok240 (why:"

# without --rule: body copied, as before
add z "Regenerate types before call-sites."
"$RELAY" knowledge graduate z --dir "$DIR" >/dev/null
assert_contains "$(cat "$INSTR")" "Regenerate types before call-sites."

# why finds a graduated lesson
out="$("$RELAY" knowledge why x --dir "$DIR")"
assert_contains "$out" "--- entry ---"
assert_contains "$out" "status: graduated"
# backslashes survive into the graduated lesson's rule field
add bs "body bs"
"$RELAY" knowledge graduate bs --rule 'Match C:\temp\new with a raw string' --dir "$DIR" >/dev/null
assert_contains "$(cat "$L/graduated/bs.md")" 'rule: Match C:\temp\new with a raw string'
pass "graduate --rule: one-line rule, verbatim, validated; why sees graduated lessons"
