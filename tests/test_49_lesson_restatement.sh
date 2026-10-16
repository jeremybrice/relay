#!/usr/bin/env bash
# test_49_lesson_restatement.sh: re-asserting a lesson with new wording keeps the previous
# wording as a tombstone (same guarantee facts get), so a paraphrase never destroys text.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
L="$DIR/knowledge/lessons"

"$RELAY" knowledge add --lesson --id dont-x "when deploying, don't run npm publish, because release.sh signs the tarball" --dir "$DIR" >/dev/null
out="$("$RELAY" knowledge add --lesson --id dont-x "avoid npm publish" --dir "$DIR")"
assert_contains "$out" "reinforced lesson: dont-x"
assert_contains "$out" "previous kept in lessons/superseded/dont-x.prev.md"
assert_file "$L/superseded/dont-x.prev.md"
assert_contains "$(cat "$L/superseded/dont-x.prev.md")" "because release.sh signs the tarball"

# same text again (whitespace aside): reinforce only, no new tombstone
"$RELAY" knowledge add --lesson --id dont-x "avoid   npm publish" --dir "$DIR" >/dev/null
assert_eq "$(ls "$L/superseded" | wc -l | tr -d ' ')" "1"
pass "lesson restatement: new wording keeps the previous text as a tombstone"
