#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

printf '## S\nbody\n' | "$RELAY" save --dir "$DIR" --digest d
"$RELAY" knowledge add --fact --id ok "valid fact body" --dir "$DIR" >/dev/null
# instruction file exists but has zero graduated markers (common default)
export RELAY_INSTRUCTION_FILE="$TMP/CLAUDE.md"
printf '# Project\nsome instructions\n' > "$RELAY_INSTRUCTION_FILE"

err="$("$RELAY" load --dir "$DIR" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q 'integer expression' && { echo "FAIL: load leaked: $err"; exit 1; } || true

pass "knowledge load: graduated-nudge count is clean (no stderr noise) with zero markers"
