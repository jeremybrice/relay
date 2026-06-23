#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
F="$DIR/knowledge/facts"

# create a fact
out="$("$RELAY" knowledge add --fact --id deploy-release-script "Deploys ship via scripts/release.sh, never npm publish." --dir "$DIR")"
assert_contains "$out" "added fact: deploy-release-script"
assert_file "$F/deploy-release-script.md"
assert_contains "$(cat "$F/deploy-release-script.md")" "confirmed: 1"
assert_contains "$(cat "$F/deploy-release-script.md")" "ttl: none"

# re-assert a SIMILAR body → confirm (bump, no overwrite of meaning, no dup file)
out="$("$RELAY" knowledge add --fact --id deploy-release-script "Deploys ship through scripts/release.sh and never npm publish directly." --dir "$DIR")"
assert_contains "$out" "confirmed: deploy-release-script"
assert_contains "$(cat "$F/deploy-release-script.md")" "confirmed: 2"
assert_contains "$(cat "$F/deploy-release-script.md")" "scripts/release.sh"

# re-assert a DIVERGENT body on the same id → conflict, NOT overwrite
out="$("$RELAY" knowledge add --fact --id deploy-release-script "Auth lives in src/auth/session.ts and uses JWT." --dir "$DIR")"
assert_contains "$out" "conflict raised for fact: deploy-release-script"
assert_file "$F/deploy-release-script.conflict"
# original body is intact (not overwritten)
assert_contains "$(cat "$F/deploy-release-script.md")" "scripts/release.sh"
assert_contains "$(cat "$F/deploy-release-script.conflict")" "Auth lives in src/auth/session.ts"
# index marks the conflict
assert_contains "$(cat "$DIR/knowledge/index.md")" "deploy-release-script · confirmed:2 · last:"
assert_contains "$(cat "$DIR/knowledge/index.md")" "conflict:1"

# --ttl persists a real freshness window (so the TTL read-side is not dead code)
"$RELAY" knowledge add --fact --id current-sprint --ttl 14 "Sprint is the checkout rewrite." --dir "$DIR" >/dev/null
assert_contains "$(cat "$DIR/knowledge/facts/current-sprint.md")" "ttl: 14"
pass "knowledge add --fact: create, confirm, conflict-not-overwrite, ttl"
