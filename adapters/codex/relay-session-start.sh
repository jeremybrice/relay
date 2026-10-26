#!/usr/bin/env bash
# Codex SessionStart hook → emits {hookSpecificOutput:{additionalContext:<handoff>}} JSON,
# which Codex adds to the model's developer context. Codex sets no project-dir variable,
# so resolve the repo root from git (the hook may run from a subdirectory).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -x "$ROOT/.relay/relay.sh" ] || exit 0
"$ROOT/.relay/relay.sh" load --dir "$ROOT/.session-log" --format codex --hook-json codex 2>/dev/null || true
exit 0
