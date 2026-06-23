#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

printf '## Summary\nhandoff body\n' | "$RELAY" save --dir "$DIR" --digest "d"
"$RELAY" knowledge add --fact   --id deploy "Deploys ship via release.sh" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --lesson --id types-first "Regen types before call-sites" --dir "$DIR" >/dev/null

out="$("$RELAY" load --dir "$DIR")"
assert_contains "$out" "handoff body"          # handoff still present
assert_contains "$out" "facts"                 # knowledge section header
assert_contains "$out" "Deploys ship via release.sh"
assert_contains "$out" "Regen types before call-sites"   # lesson BODY (load emits bodies, not ids)

# graduated lessons are NOT injected (they live in the instruction file) — assert the BODY is absent
export RELAY_INSTRUCTION_FILE="$TMP/CLAUDE.md"
"$RELAY" knowledge graduate types-first --dir "$DIR" >/dev/null 2>&1
out="$("$RELAY" load --dir "$DIR")"
[ -z "$(printf '%s' "$out" | grep -F 'Regen types before call-sites' || true)" ] || { echo "FAIL: graduated lesson double-injected"; exit 1; }

# oversized graduated-block nudge fires (1 graduated rule, soft cap forced to 1)
out="$(RELAY_GRADUATED_SOFT=1 "$RELAY" load --dir "$DIR")"
assert_contains "$out" "graduated rules"

# over-cap → explicit "N of M shown", never silent
RELAY_FACTS_CAP=8 "$RELAY" knowledge add --fact --id f2 "second fact about something else entirely here now" --dir "$DIR" >/dev/null
out="$(RELAY_FACTS_CAP=8 "$RELAY" load --dir "$DIR")"
assert_contains "$out" "of"
assert_contains "$out" "not loaded"

# codex format stays valid JSON with knowledge present
out="$("$RELAY" load --dir "$DIR" --format codex)"
assert_contains "$out" '"systemMessage"'
assert_contains "$out" '"hookEventName":"SessionStart"'
pass "knowledge load: inject, no graduated double-inject, non-silent cap, codex JSON"
