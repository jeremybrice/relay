#!/usr/bin/env bash
# test_37_install_grok.sh — --clis grok wires commands, the hook file, and the
# AGENTS.md block into a repo with no Grok config yet; idempotent; hook emits
# the top-level systemMessage Grok reads.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"; TMP="$(mktemp -d)"
( cd "$TMP" && git init -q )
( cd "$TMP" && bash "$SRC/install.sh" --clis grok --from "$SRC" </dev/null )

assert_file "$TMP/.relay/relay.sh"
assert_file "$TMP/.grok/commands/session-save.md"
assert_file "$TMP/.grok/commands/relay-learn.md"
assert_file "$TMP/.grok/hooks/relay.json"
assert_contains "$(cat "$TMP/.grok/hooks/relay.json")" "relay-session-start.sh"
assert_contains "$(cat "$TMP/AGENTS.md")" "(Grok Build)"
assert_contains "$(cat "$TMP/.gitignore")" ".session-log/"
# only grok was chosen — nothing else wired
[ ! -e "$TMP/.claude" ] || { echo "FAIL: .claude created"; exit 1; }
[ ! -e "$TMP/.codex" ]  || { echo "FAIL: .codex created"; exit 1; }
[ ! -e "$TMP/opencode.json" ] || { echo "FAIL: opencode.json created"; exit 1; }

# idempotent: re-run adds no second AGENTS.md block and doesn't nest adapters
( cd "$TMP" && bash "$SRC/install.sh" --clis grok --from "$SRC" </dev/null )
assert_eq "$(grep -c "(Grok Build)" "$TMP/AGENTS.md")" "1"
[ ! -e "$TMP/.relay/adapters/adapters" ] || { echo "FAIL: nested adapters"; exit 1; }

# hook output: top-level systemMessage carrying the handoff
( cd "$TMP" && printf '## Summary\ngrok e2e ok\n' | .relay/relay.sh save --dir "$TMP/.session-log" --digest d )
out="$(cd "$TMP" && GROK_WORKSPACE_ROOT="$TMP" bash .relay/adapters/grok/relay-session-start.sh)"
assert_contains "$out" '{"systemMessage":"'
assert_contains "$out" "grok e2e ok"
printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)'
pass "install (grok) via --clis + idempotent + systemMessage hook"
