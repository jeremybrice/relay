#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

"$RELAY" knowledge add --fact   --id deploy "ship via release.sh" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --lesson --id types-first "regen types first" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact   --id deploy "auth jwt session different" --dir "$DIR" >/dev/null   # conflict

out="$("$RELAY" knowledge list --dir "$DIR")"
assert_contains "$out" "deploy"
assert_contains "$out" "types-first"
assert_contains "$out" "conflict"

# manually corrupt the index, then list rebuilds it from files (drift self-heals)
printf 'garbage\n' > "$DIR/knowledge/index.md"
"$RELAY" knowledge list --dir "$DIR" >/dev/null
assert_contains "$(cat "$DIR/knowledge/index.md")" "lesson · types-first"
pass "knowledge list: active entries, conflict flag, index self-heal"
