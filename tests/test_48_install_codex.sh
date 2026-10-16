#!/usr/bin/env bash
# test_48_install_codex.sh: --clis codex wires .codex/hooks.json (Codex's documented hook file),
# removes the old config.toml block, merges with existing hooks, stays idempotent, and the hook
# emits SessionStart additionalContext from a subdirectory of a repo whose path has a space.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"; TMP="$(mktemp -d)/repo with space"; mkdir -p "$TMP"
( cd "$TMP" && git init -q && mkdir -p .codex sub )
printf 'model = "gpt-5"\n' > "$TMP/.codex/config.toml"
printf '# adapters/codex/hooks.relay.toml — merge into .codex/config.toml\n[[hooks.SessionStart]]\ncommand = [".relay/adapters/codex/relay-session-start.sh"]\n' \
  >> "$TMP/.codex/config.toml"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}\n' > "$TMP/.codex/hooks.json"

( cd "$TMP" && bash "$SRC/install.sh" --clis codex --from "$SRC" </dev/null >/dev/null )
( cd "$TMP" && bash "$SRC/install.sh" --clis codex --from "$SRC" </dev/null >/dev/null )   # idempotent

cfg="$(cat "$TMP/.codex/config.toml")"
assert_contains "$cfg" 'model = "gpt-5"'
[ -z "$(printf '%s' "$cfg" | grep -F 'hooks.SessionStart' || true)" ] || { echo "FAIL: legacy toml block left behind"; exit 1; }
hj="$(cat "$TMP/.codex/hooks.json")"
assert_contains "$hj" "echo mine"
assert_contains "$hj" "additionalContextLimit"
assert_eq "$(grep -o 'relay-session-start.sh' "$TMP/.codex/hooks.json" | wc -l | tr -d ' ')" "1"

printf '## Summary\nhello from codex hooks\n' | "$TMP/.relay/relay.sh" save --dir "$TMP/.session-log" --digest d
out="$(cd "$TMP/sub" && bash "$TMP/.relay/adapters/codex/relay-session-start.sh")"
assert_contains "$out" '"hookEventName":"SessionStart"'
assert_contains "$out" '"additionalContext"'
assert_contains "$out" 'hello from codex hooks'
[ -z "$(printf '%s' "$out" | grep -F 'systemMessage' || true)" ] || { echo "FAIL: still emits systemMessage"; exit 1; }
pass "codex install: hooks.json wired, legacy toml removed, merge + idempotent, additionalContext from subdir"
