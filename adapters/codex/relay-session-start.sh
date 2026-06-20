#!/usr/bin/env bash
# Codex SessionStart hook → emits {systemMessage:<handoff>} JSON.
set -euo pipefail
ROOT="${CODEX_PROJECT_DIR:-$PWD}"
[ -x "$ROOT/.relay/relay.sh" ] || exit 0
"$ROOT/.relay/relay.sh" load --dir "$ROOT/.session-log" --format codex 2>/dev/null || true
exit 0
