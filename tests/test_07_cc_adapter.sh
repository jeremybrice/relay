#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"; setup_tmp

# Simulate an installed target repo
mkdir -p "$TMP/.relay"; cp "$SRC/relay.sh" "$TMP/.relay/relay.sh"; chmod +x "$TMP/.relay/relay.sh"
cp "$SRC/adapters/claude-code/relay-session-start.sh" "$TMP/.relay/cc-start.sh"; chmod +x "$TMP/.relay/cc-start.sh"
( cd "$TMP" && printf '## Summary\nhello from cc\n' | .relay/relay.sh save --dir "$TMP/.session-log" --digest "d" )

# hook passes its stdin JSON to load and prints SessionStart JSON (additionalContext → CC context)
out="$(cd "$TMP" && printf '{"source":"startup","transcript_path":"/t/x.jsonl"}' | CLAUDE_PROJECT_DIR="$TMP" bash .relay/cc-start.sh)"
assert_contains "$out" '"additionalContext":"Last saved:'
assert_contains "$out" "hello from cc"
assert_contains "$(cat "$TMP/.session-log/.transcripts")" "/t/x.jsonl"

# command + L2 files exist and reference the save path
assert_contains "$(cat "$SRC/adapters/skills/session-save/SKILL.md")" "relay.sh"
assert_contains "$(cat "$SRC/adapters/claude-code/AGENTS.relay.md")" "/session-save"
pass "cc adapter"
