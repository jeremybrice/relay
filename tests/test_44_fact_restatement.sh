#!/usr/bin/env bash
# test_44_fact_restatement.sh: a similar-but-different restatement updates the fact (newest
# wording wins, previous kept as a tombstone) instead of silently keeping the old body.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
F="$DIR/knowledge/facts"
body() { awk 'BEGIN{d=0} /^---$/{d++; next} d>=2' "$1"; }

"$RELAY" knowledge add --fact --id deploy "Deploy with scripts/release.sh on the main branch; never npm publish" --dir "$DIR" >/dev/null
out="$("$RELAY" knowledge add --fact --id deploy "Deploy with scripts/deploy.sh on the main branch; never scripts/release.sh or npm publish" --dir "$DIR")"
assert_contains "$out" "updated wording: deploy"
assert_contains "$out" "confirmed: deploy (confirmed:2)"
assert_contains "$(body "$F/deploy.md")" "scripts/deploy.sh on the main branch"
assert_file "$F/superseded/deploy.prev.md"
assert_contains "$(cat "$F/superseded/deploy.prev.md")" "Deploy with scripts/release.sh on the main branch"

# whitespace-only restatement: plain confirm, no new tombstone
out="$("$RELAY" knowledge add --fact --id deploy "Deploy with scripts/deploy.sh on the main branch;   never scripts/release.sh or npm publish" --dir "$DIR")"
[ -z "$(printf '%s' "$out" | grep -F 'updated wording' || true)" ] || { echo "FAIL: whitespace change treated as new wording"; exit 1; }
assert_eq "$(ls "$F/superseded" | wc -l | tr -d ' ')" "1"
assert_contains "$out" "confirmed: deploy (confirmed:3)"

# a dissimilar body still raises a conflict and changes nothing
out="$("$RELAY" knowledge add --fact --id deploy "Auth lives in src/auth/session.ts and uses JWT." --dir "$DIR")"
assert_contains "$out" "conflict raised for fact: deploy"
assert_contains "$(body "$F/deploy.md")" "scripts/deploy.sh"
pass "fact restatement: newest wording wins with tombstone; whitespace confirms; divergent conflicts"
