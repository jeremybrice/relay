#!/usr/bin/env bash
# test_47_small_fixes.sh: provenance anchors only to today's session; why reports a pruned
# source; history pruning works when the data path contains a space.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
today="$(date +%F)"
yesterday="$(date -v-1d +%F 2>/dev/null || date -d yesterday +%F)"

# yesterday's latest.md must not lend its session number to today's history file
mkdir -p "$DIR/history"
printf -- '---\ndate: %s\nsession: 3\ndigest: "y"\n---\nbody\n' "$yesterday" > "$DIR/latest.md"
"$RELAY" knowledge add --lesson --id before-save "when A prefer B" --dir "$DIR" >/dev/null
assert_eq "$(sed -n 's/^source: //p' "$DIR/knowledge/lessons/before-save.md")" "history/$today.md"
printf '## Summary\nx\n' | "$RELAY" save --dir "$DIR" --digest d
"$RELAY" knowledge add --lesson --id after-save "when C prefer D" --dir "$DIR" >/dev/null
assert_eq "$(sed -n 's/^source: //p' "$DIR/knowledge/lessons/after-save.md")" "history/$today.md#session-1"

# why: a pruned source is named, not silently skipped
printf -- '---\nid: old\nkind: fact\nconfirmed: 1\nfirst_seen: 2020-01-01\nlast_confirmed: 2020-01-01\nttl: none\nsource: history/2020-01-01.md#session-1\nstatus: active\n---\nold fact body\n' \
  > "$DIR/knowledge/facts/old.md"
assert_contains "$("$RELAY" knowledge why old --dir "$DIR")" "no longer on disk"

# prune when the data dir path contains a space
SP="$(mktemp -d)/with space/.session-log"; mkdir -p "$SP/history"
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do printf 'x\n' > "$SP/history/2020-01-$i.md"; done
printf 'x\n' | "$RELAY" save --dir "$SP" --digest d
assert_eq "$(ls "$SP/history" | wc -l | tr -d ' ')" "10"
[ ! -e "$SP/history/2020-01-03.md" ] || { echo "FAIL: oldest history not pruned"; exit 1; }
assert_file "$SP/history/2020-01-04.md"
assert_file "$SP/history/$today.md"
pass "provenance anchors to today only; why names a pruned source; prune survives spaces"
