#!/usr/bin/env bash
# test_35_opencode_adapter.sh — adapter mechanics + the static-instructions load path.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"; setup_tmp

# Simulate an installed target repo: relay.sh on disk, opencode adapter copied in.
mkdir -p "$TMP/.relay/adapters/opencode/commands"
cp "$SRC/relay.sh" "$TMP/.relay/relay.sh"; chmod +x "$TMP/.relay/relay.sh"
cp "$SRC/adapters/opencode/commands/"*.md "$TMP/.relay/adapters/opencode/commands/"
cp "$SRC/adapters/opencode/AGENTS.relay.md" "$TMP/.relay/adapters/opencode/"

# Save a handoff, then refresh the snapshot the way /session-save does.
( cd "$TMP" && printf '## Summary\nhello from opencode\n' \
    | .relay/relay.sh save --dir "$TMP/.session-log" --digest "d" )
( cd "$TMP" && .relay/relay.sh load --dir "$TMP/.session-log" \
    > "$TMP/.session-log/relay-instructions.md" )

# the snapshot contains the handoff opencode will auto-load via `instructions`
assert_file "$TMP/.session-log/relay-instructions.md"
assert_contains "$(cat "$TMP/.session-log/relay-instructions.md")" "hello from opencode"
assert_contains "$(cat "$TMP/.session-log/relay-instructions.md")" "Last saved:"

# command + L2 files exist and reference the right paths
assert_contains "$(cat "$SRC/adapters/opencode/commands/session-save.md")" "relay.sh"
assert_contains "$(cat "$SRC/adapters/opencode/commands/session-save.md")" "relay-instructions.md"
assert_contains "$(cat "$SRC/adapters/opencode/commands/relay-learn.md")" "knowledge add --fact --id"
assert_contains "$(cat "$SRC/adapters/opencode/AGENTS.relay.md")" "/session-save"
assert_contains "$(cat "$SRC/adapters/opencode/instructions.relay.jsonc")" "relay-instructions.md"

# regression guard: the L2 block must point at AGENTS.md (opencode's primary
# instruction file), not CLAUDE.md — same convention as the codex adapter
assert_contains "$(cat "$SRC/adapters/opencode/AGENTS.relay.md")" "instructions"
pass "opencode adapter"
