#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

"$RELAY" knowledge add --fact   --id dup "the fact body sentinel FACTONLY" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --lesson --id dup "the lesson body sentinel LESSONONLY" --dir "$DIR" >/dev/null

out="$("$RELAY" knowledge why dup --dir "$DIR")"
assert_contains "$out" "FACTONLY"   # first match (fact) is shown deterministically

pass "knowledge why: first match (fact) wins; no silent lesson shadow"
