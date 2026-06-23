#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

BODY="$(printf 'line one about the make build\nline two about the docker image')"
"$RELAY" knowledge add --fact --id ml "$BODY" --dir "$DIR" >/dev/null

# Re-adding the identical multi-line body must CONFIRM, not conflict.
out="$("$RELAY" knowledge add --fact --id ml "$BODY" --dir "$DIR" 2>&1)"
assert_contains "$out" "confirmed: ml"
[ -e "$DIR/knowledge/facts/ml.conflict" ] && { echo "FAIL: spurious conflict on identical multi-line fact"; exit 1; } || true

# A genuinely different body still raises a conflict (similarity logic intact).
out="$("$RELAY" knowledge add --fact --id ml "completely unrelated content xyzzy plugh" --dir "$DIR" 2>&1)"
assert_contains "$out" "conflict raised"
assert_file "$DIR/knowledge/facts/ml.conflict"

pass "knowledge multi-line fact: identical body confirms, divergent body conflicts"
