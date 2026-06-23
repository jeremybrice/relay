#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
S="$DIR/knowledge/facts/superseded"

# retire the same id twice via supersede → BOTH tombstones preserved (no overwrite)
"$RELAY" knowledge add --fact --id reuse "first version of the fact" --dir "$DIR" >/dev/null
"$RELAY" knowledge supersede reuse --dir "$DIR" >/dev/null
assert_file "$S/reuse.md"
assert_contains "$(cat "$S/reuse.md")" "first version"

"$RELAY" knowledge add --fact --id reuse "second version of the fact" --dir "$DIR" >/dev/null
"$RELAY" knowledge supersede reuse --dir "$DIR" >/dev/null
assert_file "$S/reuse.2.md"                       # second tombstone gets a unique name, not an overwrite
first="$(cat "$S/reuse.md")"; second="$(cat "$S/reuse.2.md")"
assert_contains "$first$second" "first version"
assert_contains "$first$second" "second version"
[ "$first" = "$second" ] && { echo "FAIL: tombstones identical — overwrite happened"; exit 1; } || true
pass "knowledge tombstone uniqueness: repeat retire keeps both bodies"
