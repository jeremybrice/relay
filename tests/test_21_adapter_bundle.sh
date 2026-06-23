#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"

# the new adapter files exist
assert_file "$SRC/adapters/claude-code/commands/relay-learn.md"
assert_file "$SRC/adapters/codex/skills/relay-learn/SKILL.md"

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
pass "adapter: /relay-learn wired + bundle offline install + e2e capture"
