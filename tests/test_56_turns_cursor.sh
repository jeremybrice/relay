#!/usr/bin/env bash
# test_56_turns_cursor.sh: the "since last save" cursor moves only when a save succeeds, so an
# abandoned save or a repeated turns run never skips turns; one cursor line per transcript.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; FIX="$(pwd)/fixtures/turns"; setup_tmp
export HOME="$TMP/home" TZ=UTC
P="$HOME/.claude/projects/x"; mkdir -p "$P" "$DIR"
cp "$FIX/claude.jsonl" "$P/s1.jsonl"
printf 'claude\t%s\n' "$P/s1.jsonl" > "$DIR/.transcripts"
turns() { env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID "$RELAY" turns --dir "$DIR" --harness claude; }
save() { printf '## Summary\nx\n' | "$RELAY" save --dir "$DIR" --digest d; }

# abandoned save: turns twice, same turns, no cursor
first="$(turns)"; second="$(turns)"
assert_eq "$second" "$first"
[ ! -f "$DIR/.turns-cursor" ] || { echo "FAIL: cursor moved without a save"; exit 1; }

save
assert_eq "$(cat "$DIR/.turns-cursor")" "$(printf '%s\t%s' "$P/s1.jsonl" "2026-10-25T14:11:00.000Z")"
[ ! -f "$DIR/.turns-pending" ] || { echo "FAIL: pending not cleared"; exit 1; }
assert_eq "$(turns)" "relay: no new turns since the last save"

printf '%s\n' '{"type":"user","timestamp":"2026-10-25T14:30:00.000Z","message":{"role":"user","content":"one more change: rename the panel"}}' >> "$P/s1.jsonl"
out="$(turns)"
assert_contains "$out" "(since 14:11; 1 turns, 0 acknowledgements not shown)"
assert_contains "$out" '1. [14:30] you: "one more change: rename the panel"'
save
assert_eq "$(grep -c . "$DIR/.turns-cursor")" "1"
assert_contains "$(cat "$DIR/.turns-cursor")" "2026-10-25T14:30:00.000Z"

# a second transcript gets its own line
cp "$FIX/claude.jsonl" "$P/s2.jsonl"; printf 'claude\t%s\n' "$P/s2.jsonl" >> "$DIR/.transcripts"; touch "$P/s2.jsonl"
turns >/dev/null; save
assert_eq "$(grep -c . "$DIR/.turns-cursor")" "2"
pass "turns cursor: moves on save only, one line per transcript"
