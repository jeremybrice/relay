#!/usr/bin/env bash
# test_55_turns_codex_grok.sh: turns reads Codex rollouts (matched to this repo by cwd) and Grok
# prompt history (newest session, no shell lines), and auto picks the harness from the
# environment or, failing that, the newest transcript.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; FIX="$(pwd)/fixtures/turns"; setup_tmp
export HOME="$TMP/home" TZ=UTC
ROOT="$(cd "$TMP" && pwd -P)"; mkdir -p "$DIR"
clean() { env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u GROK_HOME $(env | sed -n 's/^\(CODEX_[A-Za-z0-9_]*\)=.*/-u \1/p; s/^\(GROK_[A-Za-z0-9_]*\)=.*/-u \1/p; s/^\(CURSOR_[A-Za-z0-9_]*\)=.*/-u \1/p') "$@"; }

CX="$HOME/.codex/sessions/2026/10/25"; mkdir -p "$CX"
sed "s|__ROOT__|$ROOT|g" "$FIX/codex.jsonl" > "$CX/rollout-2026-10-25T15-00-00-c1.jsonl"
out="$(clean "$RELAY" turns --dir "$DIR" --harness codex)"
assert_contains "$out" "(since session start; 2 turns, 1 acknowledgements not shown)"
assert_contains "$out" "1. [15:02] agent said: \"I set the timeout to 30 seconds in config.toml as requested earlier.\" → you: \"no that's too long, make it 10\""
assert_contains "$out" '2. [15:05] you: "now lets also log the retry count"'
[ -z "$(printf '%s' "$out" | grep -F environment_context || true)" ] || { echo "FAIL: injected context leaked"; exit 1; }

# Codex 0.163 (exec and desktop) logs prompts only as response_item user messages, beside
# injected AGENTS.md and environment blocks
sed "s|__ROOT__|$ROOT|g" "$FIX/codex_v163.jsonl" > "$CX/rollout-2026-10-25T17-00-00-c2.jsonl"
out="$(clean "$RELAY" turns --dir "$DIR" --harness codex)"
assert_contains "$out" "rollout-2026-10-25T17-00-00-c2.jsonl"
assert_contains "$out" '1. [17:01] you: "can we change the border to none?"'
assert_contains "$out" "2. [17:03] agent said: \"Set the border to none on the panel.\" → you: \"oh no that's not working on dark mode\""
for gone in "AGENTS.md instructions" "environment_context" "INSTRUCTIONS"; do
  [ -z "$(printf '%s' "$out" | grep -F -- "$gone" || true)" ] || { echo "FAIL: [$gone] leaked into codex turns"; exit 1; }
done
rm "$CX/rollout-2026-10-25T17-00-00-c2.jsonl"

GR="$HOME/.grok/sessions/$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$ROOT")"; mkdir -p "$GR"
cp "$FIX/grok_prompt_history.jsonl" "$GR/prompt_history.jsonl"
out="$(clean "$RELAY" turns --dir "$DIR" --harness grok)"
assert_contains "$out" "2 turns"
assert_contains "$out" '1. [16:00] you: "first g2 prompt"'
assert_contains "$out" "2. [16:02] you: \"oh no that's not working, can we change this?\""
for gone in "old session prompt" "ls -la" "agent said"; do
  [ -z "$(printf '%s' "$out" | grep -F -- "$gone" || true)" ] || { echo "FAIL: [$gone] in grok turns"; exit 1; }
done

# auto: environment first, then the newest transcript
assert_contains "$(clean env CODEX_THREAD_ID=x "$RELAY" turns --dir "$DIR")" "rollout-2026-10-25T15-00-00-c1.jsonl"
assert_contains "$(clean env GROK_HOME="$HOME/.grok" "$RELAY" turns --dir "$DIR")" "prompt_history.jsonl"
touch "$CX/rollout-2026-10-25T15-00-00-c1.jsonl"
assert_contains "$(clean "$RELAY" turns --dir "$DIR")" "rollout-2026-10-25T15-00-00-c1.jsonl"
touch "$GR/prompt_history.jsonl"
assert_contains "$(clean "$RELAY" turns --dir "$DIR")" "prompt_history.jsonl"

# Cursor has no transcript Relay can read: auto must not borrow another tool's session
assert_eq "$(clean env CURSOR_TRACE_ID=x "$RELAY" turns --dir "$DIR")" "relay: no transcript found for this session; save from memory"

# a rollout from another repo is not this session
sed "s|__ROOT__|/somewhere/else|g" "$FIX/codex.jsonl" > "$CX/rollout-2026-10-25T15-00-00-c1.jsonl"
assert_eq "$(clean "$RELAY" turns --dir "$DIR" --harness codex)" "relay: no transcript found for this session; save from memory"
pass "turns (Codex, Grok, auto): right file, user turns only, harness detection"
