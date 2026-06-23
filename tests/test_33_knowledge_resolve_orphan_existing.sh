#!/usr/bin/env bash
# Regression (PR #4 review #3): `resolve --keep existing` on an orphan conflict (fact .md
# gone) must REFUSE and preserve the conflict — not silently archive it and report success.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
F="$DIR/knowledge/facts"

"$RELAY" knowledge add --fact --id orph "original truth about release.sh" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact --id orph "totally divergent claim about auth jwt" --dir "$DIR" >/dev/null
assert_file "$F/orph.conflict"

# Simulate the active fact removed out-of-band, leaving an orphan conflict.
rm -f "$F/orph.md"

# --keep existing must refuse: there is no existing fact to keep.
rc=0; err="$("$RELAY" knowledge resolve orph --keep existing --dir "$DIR" 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "1"
assert_contains "$err" "no existing fact"
assert_file "$F/orph.conflict"                                  # conflict preserved, not destroyed
[ -e "$F/superseded/orph.losing.md" ] && { echo "FAIL: conflict body was wrongly tombstoned"; exit 1; }

# --keep new still promotes the orphan conflict into a fresh fact.
out="$("$RELAY" knowledge resolve orph --keep new --dir "$DIR")"
assert_contains "$out" "resolved: orph"
assert_file "$F/orph.md"
assert_contains "$(cat "$F/orph.md")" "divergent claim about auth jwt"

pass "knowledge resolve --keep existing refuses an orphan conflict (no silent data loss); --keep new still promotes"
