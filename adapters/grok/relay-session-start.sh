#!/usr/bin/env bash
# Grok SessionStart hook → emits {"systemMessage":<handoff>} JSON (Grok reads only
# a top-level systemMessage from observe-only events). AGENTS.md is the fallback.
set -euo pipefail
ROOT="${GROK_WORKSPACE_ROOT:-$PWD}"
[ -x "$ROOT/.relay/relay.sh" ] || exit 0
"$ROOT/.relay/relay.sh" load --dir "$ROOT/.session-log" --format grok --hook-json grok 2>/dev/null || true
exit 0
