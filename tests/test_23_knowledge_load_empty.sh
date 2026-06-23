#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

printf '## Summary\nhandoff body lives here\n' | "$RELAY" save --dir "$DIR" --digest "d"

# Add then retire the only fact and the only lesson, leaving empty facts/ + lessons/ dirs.
export RELAY_INSTRUCTION_FILE="$TMP/CLAUDE.md"
"$RELAY" knowledge add --fact   --id onlyfact "the build uses make"     --dir "$DIR" >/dev/null
"$RELAY" knowledge add --lesson --id onlylesson "always run the tests"  --dir "$DIR" >/dev/null
"$RELAY" knowledge supersede onlyfact --dir "$DIR" >/dev/null
"$RELAY" knowledge graduate onlylesson --dir "$DIR" >/dev/null 2>&1
# undo the graduated rule so the soft-cap nudge cannot mask the bug
"$RELAY" knowledge ungraduate onlylesson --dir "$DIR" >/dev/null 2>&1

# load MUST still succeed and still print the handoff
rc=0; out="$("$RELAY" load --dir "$DIR")" || rc=$?
assert_eq "$rc" "0"
assert_contains "$out" "handoff body lives here"

# also: knowledge dir present but completely empty (only the dirs exist)
setup_tmp
printf '## Summary\nsecond handoff\n' | "$RELAY" save --dir "$DIR" --digest "d"
mkdir -p "$DIR/knowledge/facts" "$DIR/knowledge/lessons"
rc=0; out="$("$RELAY" load --dir "$DIR")" || rc=$?
assert_eq "$rc" "0"
assert_contains "$out" "second handoff"

pass "knowledge load: empty/retired knowledge never aborts the handoff"
