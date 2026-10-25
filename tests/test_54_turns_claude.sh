#!/usr/bin/env bash
# test_54_turns_claude.sh: turns prints the user's own turns from the Claude Code transcript
# (dictation kept, system text dropped, rejections shown, long turns clipped, acks counted),
# picks the right session, and degrades to a one-line message instead of failing.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; FIX="$(pwd)/fixtures/turns"; setup_tmp
export HOME="$TMP/home" TZ=UTC
ROOT="$(cd "$TMP" && pwd -P)"; ENC="$(printf '%s' "$ROOT" | sed 's/[^A-Za-z0-9]/-/g')"
P="$HOME/.claude/projects/$ENC"; mkdir -p "$P" "$DIR"
cp "$FIX/claude.jsonl" "$P/s1.jsonl"
printf 'claude\t%s\n' "$P/s1.jsonl" > "$DIR/.transcripts"
turns() { env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID "$@"; }

out="$(turns "$RELAY" turns --dir "$DIR" --harness claude)"
assert_contains "$out" "## Your turns this session (since session start; 5 turns, 2 acknowledgements not shown)"
assert_contains "$out" "(transcript: $P/s1.jsonl)"
assert_contains "$out" '1. [14:02] agent said: "I rendered the panel with the default 2px border as the design shows." → you: "can we change this? the border looks heavy"'
# turns keeps pasted dictation
assert_contains "$out" "2. [14:05] you: \"okay let's try this instead, no border\""
assert_contains "$out" "3. [14:06] you rejected a tool call: \"don't touch the theme file\""
assert_contains "$out" '5. [14:11] you: "the shadow looks muddy on dark mode"'
for gone in "meta expansion" "command-name" "sidechain secret" "command not found" "pasted_content" "[Image"; do
  [ -z "$(printf '%s' "$out" | grep -F -- "$gone" || true)" ] || { echo "FAIL: [$gone] leaked into turns"; exit 1; }
done
line4="$(printf '%s\n' "$out" | grep '^4\. ')"
assert_contains "$line4" "LONGSTART"; assert_contains "$line4" " … "; assert_contains "$line4" "LONGEND"
youpart="${line4#*→ you: }"
[ "$(printf '%s' "$youpart" | wc -w | tr -d ' ')" -le 82 ] || { echo "FAIL: long turn not clipped"; exit 1; }
agentpart="$(printf '%s' "$line4" | sed 's/.*agent said: "\(.*\)" → you:.*/\1/')"
assert_contains "$agentpart" "…"
[ "$(printf '%s' "${agentpart#…}" | wc -w | tr -d ' ')" -eq 25 ] || { echo "FAIL: agent context not 25 words: $agentpart"; exit 1; }
assert_eq "$(cat "$DIR/.turns-pending")" "$(printf '%s\t%s' "$P/s1.jsonl" "2026-10-25T14:11:00.000Z")"

# turns picks the session from CLAUDE_CODE_SESSION_ID even when another transcript is newer
printf '%s\n' '{"type":"user","timestamp":"2026-10-25T15:00:00.000Z","message":{"role":"user","content":"other window prompt"}}' > "$P/s2.jsonl"
printf 'claude\t%s\n' "$P/s2.jsonl" >> "$DIR/.transcripts"; touch "$P/s2.jsonl"
assert_contains "$(env -u CLAUDECODE CLAUDE_CODE_SESSION_ID=s1 "$RELAY" turns --dir "$DIR" --harness claude)" "(transcript: $P/s1.jsonl)"
assert_contains "$(turns "$RELAY" turns --dir "$DIR" --harness claude)" "(transcript: $P/s2.jsonl)"
# session id not in .transcripts: found by searching the projects folders
rm "$DIR/.transcripts"
assert_contains "$(env -u CLAUDECODE CLAUDE_CODE_SESSION_ID=s1 "$RELAY" turns --dir "$DIR" --harness claude)" "(transcript: $P/s1.jsonl)"
# no notes, no session id: newest transcript in this repo's projects folder
assert_contains "$(turns "$RELAY" turns --dir "$DIR" --harness claude)" "(transcript: $P/s2.jsonl)"

# cap: oldest turns dropped, newest kept
rm "$P/s2.jsonl"
out="$(turns env RELAY_TURNS_CAP=40 "$RELAY" turns --dir "$DIR" --harness claude)"
assert_match "$out" "older turns dropped\)$"
assert_contains "$out" "the shadow looks muddy on dark mode"

# degrade, exit 0
rm -rf "$HOME/.claude"
out="$(turns "$RELAY" turns --dir "$DIR" --harness claude)"
assert_eq "$out" "relay: no transcript found for this session; save from memory"
out="$(turns env RELAY_PYTHON=/nonexistent "$RELAY" turns --dir "$DIR" --harness claude)"
assert_eq "$out" "relay: turns needs python3; save from memory"
assert_exit 2 "$RELAY" turns --dir "$DIR" --harness cursor
pass "turns (Claude Code): own turns, dictation kept, right session, graceful fallbacks"
