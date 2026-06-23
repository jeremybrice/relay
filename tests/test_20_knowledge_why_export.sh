#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

printf '## Summary\nthe origin session\n' | "$RELAY" save --dir "$DIR" --digest "d"
"$RELAY" knowledge add --fact   --id deploy "ship via release.sh" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --lesson --id types-first "regen types first" --dir "$DIR" >/dev/null

# why prints the entry + its provenance source
out="$("$RELAY" knowledge why deploy --dir "$DIR")"
assert_contains "$out" "ship via release.sh"
assert_contains "$out" "source:"

# export concatenates active entries
out="$("$RELAY" knowledge export --dir "$DIR")"
assert_contains "$out" "ship via release.sh"
assert_contains "$out" "regen types first"
pass "knowledge why + export"
