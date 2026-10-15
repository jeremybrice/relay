#!/usr/bin/env bash
# test_39_install_upgrade.sh — re-install rewrites an existing adapter block in
# place (no duplicate, new wording, surrounding text kept) and finds an
# OpenCode config living at .opencode/opencode.json.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"; TMP="$(mktemp -d)"
( cd "$TMP" && git init -q && mkdir .opencode )
printf '{ "$schema": "https://opencode.ai/config.json", "instructions": ["AGENTS.md"] }\n' > "$TMP/.opencode/opencode.json"
cat > "$TMP/AGENTS.md" <<'MD'
# My repo
before

# >>> relay >>>
<!-- adapters/opencode/AGENTS.relay.md -->
## Relay — session handoff (L2)
old wording
# <<< relay <<<

after
MD
( cd "$TMP" && bash "$SRC/install.sh" --clis opencode --from "$SRC" </dev/null >/dev/null )
a="$(cat "$TMP/AGENTS.md")"
assert_contains "$a" "(OpenCode)"
assert_contains "$a" "before"
assert_contains "$a" "after"
printf '%s' "$a" | grep -qF "old wording" && { echo "FAIL: old block kept"; exit 1; }
assert_eq "$(grep -c 'adapters/opencode/AGENTS.relay.md' "$TMP/AGENTS.md")" "1"
assert_contains "$(cat "$TMP/.opencode/opencode.json")" "relay-instructions.md"
[ ! -e "$TMP/opencode.json" ] || { echo "FAIL: created a second root opencode.json"; exit 1; }
pass "install upgrades blocks in place + .opencode/opencode.json"

# a source checkout runs without --from (finds its own adapters)
TMP2="$(mktemp -d)"; ( cd "$TMP2" && git init -q )
( cd "$TMP2" && bash "$SRC/install.sh" --clis cursor </dev/null >/dev/null )
assert_file "$TMP2/.cursor/skills/relay-compact/SKILL.md"
[ -s "$TMP2/.relay/relay.sh" ] || { echo "FAIL: empty relay.sh"; exit 1; }
pass "source install.sh works without --from"
