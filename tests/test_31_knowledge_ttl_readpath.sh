#!/usr/bin/env bash
# Regression (PR #4 review #1 + round-2 follow-up): a ttl already on disk that is non-numeric,
# oversized-numeric, or whitespace-padded must NOT leak `integer expression expected` on the read
# paths (load, prune) and must resolve to a sane freshness window.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
F="$DIR/knowledge/facts"

printf '## Summary\nhandoff\n' | "$RELAY" save --dir "$DIR" --digest "d" >/dev/null

# --- non-numeric ttl on disk (e.g. "30d" from pre-fix code / a hand-edit) ---
"$RELAY" knowledge add --fact --id legacy "old truth about the build" --ttl 30 --dir "$DIR" >/dev/null
sed -i.bak -e 's/^ttl: .*/ttl: 30d/' -e 's/^last_confirmed: .*/last_confirmed: 2000-01-01/' "$F/legacy.md"; rm -f "$F/legacy.md.bak"
assert_contains "$(cat "$F/legacy.md")" "ttl: 30d"

rc=0; out="$("$RELAY" load --dir "$DIR" 2>"$TMP/err")" || rc=$?
assert_eq "$rc" "0"
grep -q 'integer expression' "$TMP/err" && { echo "FAIL: load ttl read-path leaked: $(cat "$TMP/err")"; exit 1; }
assert_contains "$out" "past freshness window"

out="$("$RELAY" knowledge prune --dir "$DIR" 2>"$TMP/perr")"
grep -q 'integer expression' "$TMP/perr" && { echo "FAIL: prune ttl read-path leaked: $(cat "$TMP/perr")"; exit 1; }
assert_contains "$out" "legacy"

# --- oversized purely-numeric ttl on disk (would overflow `[ -gt ]` if passed through) ---
"$RELAY" knowledge add --fact --id big "another truth" --dir "$DIR" >/dev/null
sed -i.bak -e 's/^ttl: .*/ttl: 99999999999999999999/' -e 's/^last_confirmed: .*/last_confirmed: 2000-01-01/' "$F/big.md"; rm -f "$F/big.md.bak"
out="$("$RELAY" knowledge prune --dir "$DIR" 2>"$TMP/oerr")"
grep -q 'integer expression' "$TMP/oerr" && { echo "FAIL: oversized-numeric ttl leaked: $(cat "$TMP/oerr")"; exit 1; }
assert_contains "$out" "big"

# --- trailing-whitespace numeric ttl is honored (trimmed), not silently widened to the default ---
"$RELAY" knowledge add --fact --id ws "ws truth" --ttl 5 --dir "$DIR" >/dev/null
sed -i.bak -e 's/^ttl: 5$/ttl: 5 /' -e 's/^last_confirmed: .*/last_confirmed: 2000-01-01/' "$F/ws.md"; rm -f "$F/ws.md.bak"
out="$("$RELAY" knowledge prune --dir "$DIR" 2>"$TMP/wserr")"
grep -q 'integer expression' "$TMP/wserr" && { echo "FAIL: trailing-space ttl leaked: $(cat "$TMP/wserr")"; exit 1; }
assert_contains "$out" "ws"

# --- write path caps an absurd ttl with a clean error instead of storing an unsafe value ---
rc=0; werr="$("$RELAY" knowledge add --fact --id toolong x --ttl 99999999999999999999 --dir "$DIR" 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "2"
assert_contains "$werr" "--ttl too large"
[ -e "$F/toolong.md" ] && { echo "FAIL: an over-large ttl fact was written"; exit 1; }

pass "knowledge ttl read-path: non-numeric / oversized / whitespace ttl never leak, write caps magnitude"
