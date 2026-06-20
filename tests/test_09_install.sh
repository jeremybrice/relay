#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"; TMP="$(mktemp -d)"

# target repo with Claude Code present
mkdir -p "$TMP/.claude"; ( cd "$TMP" && git init -q )
( cd "$TMP" && RELAY_SRC="$SRC" bash "$SRC/install.sh" --from "$SRC" )

assert_file "$TMP/.relay/relay.sh"
assert_file "$TMP/.claude/settings.json"
assert_contains "$(cat "$TMP/.gitignore")" ".session-log/"
assert_contains "$(cat "$TMP/.claude/settings.json")" "relay-session-start.sh"

# idempotent: second run adds no duplicate hook
before="$(grep -c "relay-session-start" "$TMP/.claude/settings.json")"
( cd "$TMP" && RELAY_SRC="$SRC" bash "$SRC/install.sh" --from "$SRC" )
after="$(grep -c "relay-session-start" "$TMP/.claude/settings.json")"
assert_eq "$before" "$after"
pass "install (cc) + idempotent + gitignore"
