#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

# empty state: silent, exit 0
out="$("$RELAY" load --dir "$DIR")"; assert_eq "$out" ""

# fresh save → "today"
printf '## Summary\nload me, see app.ts\n' | "$RELAY" save --dir "$DIR" --digest "d"
out="$("$RELAY" load --dir "$DIR")"
assert_contains "$out" "Last saved:"
assert_contains "$out" "(today)"
assert_contains "$out" "load me, see app.ts"
assert_contains "$out" "Session index"

# stale: backdate latest.md's frontmatter 9 days → ⚠ flag
old="$(date -v-9d +%F 2>/dev/null || date -d '9 days ago' +%F)"
tmp="$(mktemp)"; sed "s/^date: .*/date: $old/" "$DIR/latest.md" > "$tmp"; mv "$tmp" "$DIR/latest.md"
out="$("$RELAY" load --dir "$DIR")"
assert_contains "$out" "⚠"
assert_contains "$out" "days ago"

# codex format → JSON systemMessage
out="$("$RELAY" load --dir "$DIR" --format codex)"
assert_contains "$out" '"systemMessage"'
assert_contains "$out" '"hookEventName":"SessionStart"'
pass "load + staleness + codex format"
