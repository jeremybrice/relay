#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"; setup_tmp
mkdir -p "$TMP/.relay"; cp "$SRC/relay.sh" "$TMP/.relay/relay.sh"; chmod +x "$TMP/.relay/relay.sh"
cp "$SRC/adapters/codex/relay-session-start.sh" "$TMP/.relay/cx-start.sh"; chmod +x "$TMP/.relay/cx-start.sh"
( cd "$TMP" && printf '## Summary\nhello from codex\n' | .relay/relay.sh save --dir "$TMP/.session-log" --digest "d" )

out="$(cd "$TMP" && CODEX_PROJECT_DIR="$TMP" bash .relay/cx-start.sh)"
assert_contains "$out" '"systemMessage"'
assert_contains "$out" 'hello from codex'
# config + L2 + skill present
assert_contains "$(cat "$SRC/adapters/codex/hooks.relay.toml")" "SessionStart"
assert_contains "$(cat "$SRC/adapters/codex/skills/session-save/SKILL.md")" "relay.sh"
assert_contains "$(cat "$SRC/adapters/codex/AGENTS.relay.md")" "session-log"
# relay-learn records a FACT with --fact --id (regression: issue #3 — was --lesson)
assert_contains "$(cat "$SRC/adapters/codex/skills/relay-learn/SKILL.md")" "knowledge add --fact --id"
pass "codex adapter"
