#!/usr/bin/env bash
# test_36_install_opencode.sh — installer detects .opencode/, wires commands +
# the instructions entry idempotently, seeds the snapshot, gitignores the data.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"; TMP="$(mktemp -d)"

# target repo with opencode present (marker dir + an existing opencode.json)
mkdir -p "$TMP/.opencode"; ( cd "$TMP" && git init -q )
printf '{ "$schema": "https://opencode.ai/config.json" }\n' > "$TMP/opencode.json"
( cd "$TMP" && bash "$SRC/install.sh" --from "$SRC" )

# tool laid down
assert_file "$TMP/.relay/relay.sh"
# commands wired into .opencode/commands/
assert_file "$TMP/.opencode/commands/session-save.md"
assert_file "$TMP/.opencode/commands/relay-learn.md"
# L2 block appended to AGENTS.md
assert_contains "$(cat "$TMP/AGENTS.md")" "/session-save"
# instructions entry merged into opencode.json + snapshot seeded
assert_contains "$(cat "$TMP/opencode.json")" "relay-instructions.md"
assert_contains "$(cat "$TMP/opencode.json")" "instructions"
assert_file "$TMP/.session-log/relay-instructions.md"
# data is gitignored
assert_contains "$(cat "$TMP/.gitignore")" ".session-log/"

# idempotent: second run adds no duplicate instructions entry
before="$(grep -c "relay-instructions.md" "$TMP/opencode.json")"
( cd "$TMP" && bash "$SRC/install.sh" --from "$SRC" )
after="$(grep -c "relay-instructions.md" "$TMP/opencode.json")"
assert_eq "$before" "$after"

# jsonc variant: installer merges into opencode.jsonc when that's what's present
TMP2="$(mktemp -d)"; mkdir -p "$TMP2/.opencode"; ( cd "$TMP2" && git init -q )
printf '{ "$schema": "https://opencode.ai/config.json" }\n' > "$TMP2/opencode.jsonc"
( cd "$TMP2" && bash "$SRC/install.sh" --from "$SRC" )
assert_contains "$(cat "$TMP2/opencode.jsonc")" "relay-instructions.md"
pass "install (opencode) + idempotent + jsonc + gitignore"
