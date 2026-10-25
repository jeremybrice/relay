#!/usr/bin/env bash
# Claude Code SessionStart hook → passes the hook JSON (stdin) to relay.sh, which emits
# {systemMessage?, hookSpecificOutput:{additionalContext:<handoff>}} JSON.
set -euo pipefail
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -x "$ROOT/.relay/relay.sh" ] || exit 0
"$ROOT/.relay/relay.sh" load --dir "$ROOT/.session-log" --format claude --hook-json claude 2>/dev/null || true
exit 0
