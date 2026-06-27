#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"

# the new adapter files exist
assert_file "$SRC/adapters/claude-code/commands/relay-learn.md"
assert_file "$SRC/adapters/codex/skills/relay-learn/SKILL.md"
assert_file "$SRC/adapters/opencode/commands/relay-learn.md"
assert_file "$SRC/adapters/opencode/commands/session-save.md"
assert_file "$SRC/adapters/opencode/AGENTS.relay.md"
assert_file "$SRC/adapters/opencode/instructions.relay.jsonc"

# bundle regenerates and offline-installs into a fresh CC repo, wiring /relay-learn
( cd "$SRC" && bash bundle.sh )
assert_file "$SRC/dist/install.sh"
TMP="$(mktemp -d)"; mkdir -p "$TMP/.claude"; ( cd "$TMP" && git init -q )
( cd "$TMP" && bash "$SRC/dist/install.sh" )
assert_file "$TMP/.claude/commands/relay-learn.md"
assert_file "$TMP/.relay/relay.sh"

# the wired tool can capture knowledge end to end
( cd "$TMP" && .relay/relay.sh knowledge add --lesson --id e2e "end to end works" --dir "$TMP/.session-log" >/dev/null )
assert_file "$TMP/.session-log/knowledge/lessons/e2e.md"

# bundle also offline-installs into a fresh opencode repo and wires /session-save
TMP2="$(mktemp -d)"; mkdir -p "$TMP2/.opencode"; ( cd "$TMP2" && git init -q )
( cd "$TMP2" && bash "$SRC/dist/install.sh" )
assert_file "$TMP2/.opencode/commands/session-save.md"
assert_file "$TMP2/.opencode/commands/relay-learn.md"
assert_file "$TMP2/.session-log/relay-instructions.md"
# save → refresh snapshot → snapshot contains the handoff opencode will auto-load
( cd "$TMP2" && printf '## Summary\nopencode e2e ok\n' \
    | .relay/relay.sh save --dir "$TMP2/.session-log" --digest "d2" )
( cd "$TMP2" && .relay/relay.sh load --dir "$TMP2/.session-log" \
    > "$TMP2/.session-log/relay-instructions.md" )
assert_contains "$(cat "$TMP2/.session-log/relay-instructions.md")" "opencode e2e ok"
pass "adapter: /relay-learn wired + bundle offline install + opencode e2e"
