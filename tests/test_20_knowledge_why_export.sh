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
assert_contains "$out" "came from"            # the provenance history-excerpt section rendered
assert_contains "$out" "the origin session"   # the referenced handoff body appears in the excerpt

# export concatenates active entries
out="$("$RELAY" knowledge export --dir "$DIR")"
assert_contains "$out" "ship via release.sh"
assert_contains "$out" "regen types first"

# export excludes retired entries: supersede moves them to superseded/, out of the depth-1 glob
"$RELAY" knowledge add --fact --id retired "this fact is now retired" --dir "$DIR" >/dev/null
"$RELAY" knowledge supersede retired --dir "$DIR" >/dev/null
out="$("$RELAY" knowledge export --dir "$DIR")"
assert_contains "$out" "ship via release.sh"   # active entry still exported
[ -z "$(printf '%s' "$out" | grep -F 'this fact is now retired' || true)" ] || { echo "FAIL: retired entry leaked into export"; exit 1; }
pass "knowledge why (provenance excerpt) + export (active-only)"
