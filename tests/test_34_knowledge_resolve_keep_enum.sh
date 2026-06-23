#!/usr/bin/env bash
# Regression (PR #4 review #4): `resolve --keep <typo>` must be rejected, not silently
# treated as `existing` (which would discard the new body and echo the typo as success).
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
F="$DIR/knowledge/facts"

"$RELAY" knowledge add --fact --id e "keep me original body" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact --id e "divergent body about something else" --dir "$DIR" >/dev/null
assert_file "$F/e.conflict"

# A typo'd --keep value is rejected up front.
rc=0; err="$("$RELAY" knowledge resolve e --keep neww --dir "$DIR" 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "1"
assert_contains "$err" "must be 'new' or 'existing'"

# Nothing was changed: conflict still pending, original fact intact, no tombstone written.
assert_file "$F/e.conflict"
assert_contains "$(cat "$F/e.md")" "keep me original body"
[ -e "$F/superseded/e.losing.md" ] && { echo "FAIL: a tombstone was written for a rejected resolve"; exit 1; }

pass "knowledge resolve validates --keep enum (typo rejected, conflict untouched)"
