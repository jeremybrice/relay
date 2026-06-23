#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
F="$DIR/knowledge/facts"

"$RELAY" knowledge add --fact --id fresh "recently true" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact --id old-ttl "sprint is X" --dir "$DIR" >/dev/null

# backdate old-ttl's last_confirmed 30 days and give it ttl:14 → expired
old="$(date -v-30d +%F 2>/dev/null || date -d '30 days ago' +%F)"
tmp="$(mktemp)"; sed -e "s/^last_confirmed: .*/last_confirmed: $old/" -e "s/^ttl: .*/ttl: 14/" "$F/old-ttl.md" > "$tmp"; mv "$tmp" "$F/old-ttl.md"

# dry run proposes old-ttl, not fresh; writes nothing
out="$("$RELAY" knowledge prune --dir "$DIR")"
assert_contains "$out" "old-ttl"
assert_file "$F/fresh.md"; assert_file "$F/old-ttl.md"

# --yes applies
"$RELAY" knowledge prune --yes --dir "$DIR" >/dev/null
assert_file "$F/superseded/old-ttl.md"
assert_file "$F/fresh.md"
pass "knowledge prune: gated staleness review (dry-run + --yes)"
