#!/usr/bin/env bash
# test_38_install_cli_picker.sh — the interactive picker pre-checks detected
# CLIs, toggles by number, and wires only the final selection. Multiple
# AGENTS.md adapters each get their own block. --clis rejects unknown names.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"; TMP="$(mktemp -d)"
( cd "$TMP" && git init -q && mkdir .claude )

# claude is detected (pre-checked); toggle it off, turn on codex (2), cursor (4), grok (5)
printf '1 2\n4 5\n\n' > "$TMP/answers"
( cd "$TMP" && RELAY_TTY="$TMP/answers" bash "$SRC/install.sh" --from "$SRC" 2>"$TMP/err" )
assert_contains "$(cat "$TMP/err")" "[x] Claude Code"
assert_file "$TMP/.codex/hooks.json"
assert_file "$TMP/.grok/hooks/relay.json"
assert_file "$TMP/.cursor/skills/session-save/SKILL.md"
assert_contains "$(cat "$TMP/AGENTS.md")" "(Cursor)"
[ ! -e "$TMP/.claude/settings.json" ] || { echo "FAIL: claude wired though deselected"; exit 1; }
assert_contains "$(cat "$TMP/AGENTS.md")" "(Codex)"
assert_contains "$(cat "$TMP/AGENTS.md")" "(Grok Build)"

# "a" selects all five; codex + opencode + cursor + grok blocks all land in AGENTS.md
TMP2="$(mktemp -d)"; ( cd "$TMP2" && git init -q )
printf 'a\n\n' > "$TMP2/answers"
( cd "$TMP2" && RELAY_TTY="$TMP2/answers" bash "$SRC/install.sh" --from "$SRC" 2>/dev/null )
assert_file "$TMP2/.claude/settings.json"
assert_file "$TMP2/opencode.json"
assert_contains "$(cat "$TMP2/opencode.json")" "relay-instructions.md"
for h in "(Codex)" "(OpenCode)" "(Cursor)" "(Grok Build)"; do assert_contains "$(cat "$TMP2/AGENTS.md")" "$h"; done

# --clis accepts aliases and commas; rejects unknown names
TMP3="$(mktemp -d)"; ( cd "$TMP3" && git init -q )
( cd "$TMP3" && bash "$SRC/install.sh" --clis "Claude-Code,OpenCode" --from "$SRC" </dev/null >/dev/null )
assert_file "$TMP3/.claude/settings.json"
assert_file "$TMP3/opencode.json"
assert_exit 2 bash -c "cd '$TMP3' && bash '$SRC/install.sh' --clis windsurf --from '$SRC'"
pass "install picker + multi-adapter AGENTS.md + --clis aliases"
