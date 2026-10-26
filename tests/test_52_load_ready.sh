#!/usr/bin/env bash
# test_52_load_ready.sh: on a fresh start, load puts graduation-ready lessons (at most 3, own
# word budget, deferred ones hidden) in a Ready block above the handoff, and leaves them out of
# the normal lessons list.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
L="$DIR/knowledge/lessons"
setfm() { sed -i.bak "s/^$2: .*/$2: $3/" "$1" && rm -f "$1.bak"; }
lesson() { "$RELAY" knowledge add --lesson --id "$1" "$3" --dir "$DIR" >/dev/null; setfm "$L/$1.md" sessions "$2"; }
printf '## Summary\nthe handoff\n' | "$RELAY" save --dir "$DIR" --digest d

# no ready lessons: --fresh changes nothing
lesson low 1 "when L, do M"
assert_eq "$("$RELAY" load --fresh --dir "$DIR")" "$("$RELAY" load --dir "$DIR")"

lesson s6 6 "body six"; lesson s5 5 "body five"; lesson s4 4 "body four"; lesson s3 3 "body three"
out="$("$RELAY" load --fresh --dir "$DIR")"
assert_contains "$out" "## Ready to become rules (ask before starting work)"
assert_contains "$out" "Use a multiple-choice question tool if you have one, otherwise a numbered list. If the user skips the question, record nothing."
ready="$(printf '%s\n' "$out" | sed -n '/^## Ready to become rules/,/^## Summary/p')"
assert_eq "$(printf '%s\n' "$ready" | grep '^- `' | sed 's/^- `\([a-z0-9]*\)`.*/\1/' | tr '\n' ' ')" "s6 s5 s4 "
assert_contains "$ready" '- `s6` (sessions:6): body six'
assert_contains "$ready" "(+1 more ready; they come up next session)"
assert_contains "$ready" "## Summary"   # block sits above the handoff
lessons="$(printf '%s\n' "$out" | sed -n '/^## What this repo knows — lessons/,$p')"
for id in s6 s5 s4; do [ -z "$(printf '%s' "$lessons" | grep -F "\`$id\`" || true)" ] || { echo "FAIL: $id repeated in lessons list"; exit 1; }; done
assert_contains "$lessons" '`low`'
assert_contains "$lessons" '`s3`'

# without --fresh: no Ready block, every lesson in the normal list
out="$("$RELAY" load --dir "$DIR")"
[ -z "$(printf '%s' "$out" | grep -F 'Ready to become rules' || true)" ] || { echo "FAIL: Ready block without --fresh"; exit 1; }
assert_contains "$out" '`s6`'

# deferred at its current count: hidden; one more session: back
"$RELAY" knowledge defer s6 --dir "$DIR" >/dev/null
out="$("$RELAY" load --fresh --dir "$DIR")"
[ -z "$(printf '%s' "$out" | sed -n '/^## Ready/,/^## Summary/p' | grep -F '`s6`' || true)" ] || { echo "FAIL: deferred lesson shown"; exit 1; }
setfm "$L/s6.md" sessions 7
assert_contains "$("$RELAY" load --fresh --dir "$DIR")" '- `s6` (sessions:7)'

# budget: three 350-word ready lessons -> only the first shown
setup_tmp; L="$DIR/knowledge/lessons"
printf '## Summary\nh\n' | "$RELAY" save --dir "$DIR" --digest d
big="$(printf 'word%.0s ' $(seq 1 350))"
lesson b1 5 "first $big"; lesson b2 4 "second $big"; lesson b3 3 "third $big"
ready="$("$RELAY" load --fresh --dir "$DIR" | sed -n '/^## Ready/,/^## Summary/p')"
assert_eq "$(printf '%s\n' "$ready" | grep -c '^- `')" "1"
assert_contains "$ready" '- `b1`'
assert_contains "$ready" "(+2 more ready; they come up next session)"
pass "load --fresh: Ready block, capped, budgeted, deferral-aware, not repeated"
