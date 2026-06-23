#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

"$RELAY" knowledge add --fact --id deploy-release-script "Deploys ship via scripts/release.sh." --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact --id test-db-resets "The integration test database resets every run." --dir "$DIR" >/dev/null

# --near surfaces the closest existing id, writes nothing new
before="$(ls "$DIR/knowledge/facts" | wc -l | tr -d ' ')"
out="$("$RELAY" knowledge add --fact --near "How do we ship a release / deploy?" --dir "$DIR")"
assert_contains "$out" "deploy-release-script"
after="$(ls "$DIR/knowledge/facts" | wc -l | tr -d ' ')"
assert_eq "$after" "$before"

# --near on an empty store says so, writes nothing
setup_tmp
out="$("$RELAY" knowledge add --fact --near "anything" --dir "$DIR")"
assert_contains "$out" "no"
pass "knowledge add --near: candidate ids, no write"
