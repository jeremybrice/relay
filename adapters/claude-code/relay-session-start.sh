#!/usr/bin/env bash
# Claude Code SessionStart hook → prints the Relay handoff (stdout is injected into context).
set -euo pipefail
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -x "$ROOT/.relay/relay.sh" ] || exit 0
"$ROOT/.relay/relay.sh" load --dir "$ROOT/.session-log" 2>/dev/null || true
exit 0
