#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
today="$(date +%F)"
KD="$DIR/knowledge/lessons"

# create a lesson
out="$("$RELAY" knowledge add --lesson --id schema-types-first "Regenerate types before call-sites." --dir "$DIR")"
assert_contains "$out" "added lesson: schema-types-first"
assert_file "$KD/schema-types-first.md"
assert_contains "$(cat "$KD/schema-types-first.md")" "seen: 1"
assert_contains "$(cat "$KD/schema-types-first.md")" "sessions: 1"
assert_contains "$(cat "$KD/schema-types-first.md")" "Regenerate types before call-sites."
assert_contains "$(cat "$KD/schema-types-first.md")" "source: history/$today.md"

# reinforce SAME day → seen bumps, sessions unchanged
out="$("$RELAY" knowledge add --lesson --id schema-types-first "Regen types first, always." --dir "$DIR")"
assert_contains "$out" "reinforced lesson: schema-types-first"
assert_contains "$(cat "$KD/schema-types-first.md")" "seen: 2"
assert_contains "$(cat "$KD/schema-types-first.md")" "sessions: 1"
assert_contains "$(cat "$KD/schema-types-first.md")" "Regen types first, always."

# slug normalization: messy --id is normalized
"$RELAY" knowledge add --lesson --id "Use Tabs, Not Spaces!" "tabs here" --dir "$DIR" >/dev/null
assert_file "$KD/use-tabs-not-spaces.md"

# derived index lists the active lessons
assert_file "$DIR/knowledge/index.md"
assert_contains "$(cat "$DIR/knowledge/index.md")" "lesson · schema-types-first · seen:2 · sessions:1"

# distinct-session gate (R6): reinforce on a LATER day → sessions increments (not just seen)
old="$(date -v-2d +%F 2>/dev/null || date -d '2 days ago' +%F)"
tmp="$(mktemp)"; sed "s/^last_seen: .*/last_seen: $old/" "$KD/schema-types-first.md" > "$tmp"; mv "$tmp" "$KD/schema-types-first.md"
"$RELAY" knowledge add --lesson --id schema-types-first "Regen types, day two." --dir "$DIR" >/dev/null
assert_contains "$(cat "$KD/schema-types-first.md")" "sessions: 2"

# a third distinct day reaches the gate → the graduation-ready prompt appears
tmp="$(mktemp)"; sed "s/^last_seen: .*/last_seen: $old/" "$KD/schema-types-first.md" > "$tmp"; mv "$tmp" "$KD/schema-types-first.md"
out="$("$RELAY" knowledge add --lesson --id schema-types-first "Regen types, day three." --dir "$DIR")"
assert_contains "$(cat "$KD/schema-types-first.md")" "sessions: 3"
assert_contains "$out" "graduation-ready"
pass "knowledge add --lesson: create, same-day reinforce, distinct-session gate, slug, index"
