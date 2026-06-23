#!/usr/bin/env bash
# Regression (PR #4 review #2 + round-2 follow-up): every value-taking flag given as the final
# token must yield a clean usage error, NOT a raw `$2: unbound variable` crash under `set -u`;
# and a value flag immediately followed by another flag must be rejected, not swallowed.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

assert_no_crash() { case "$1" in *"unbound variable"*) echo "FAIL: leaked set -u crash: $1"; exit 1;; esac; }

# --- knowledge sub-flags: --ttl / --id (k_add), --keep (k_resolve) as the last token ---
rc=0; err="$(cd "$TMP" && "$RELAY" knowledge add --fact body --ttl 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "2"; assert_contains "$err" "--ttl needs a value"; assert_no_crash "$err"

rc=0; err="$(cd "$TMP" && "$RELAY" knowledge add --fact body --id 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "2"; assert_contains "$err" "--id needs a value"; assert_no_crash "$err"

rc=0; err="$(cd "$TMP" && "$RELAY" knowledge resolve someid --keep 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "1"; assert_contains "$err" "--keep needs a value"; assert_no_crash "$err"

# --- the knowledge-group dispatcher's own --dir, and the top-level save/load value flags ---
rc=0; err="$(cd "$TMP" && "$RELAY" knowledge --dir 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "2"; assert_contains "$err" "--dir needs a value"; assert_no_crash "$err"

rc=0; err="$(cd "$TMP" && printf 'x' | "$RELAY" save --digest 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "2"; assert_contains "$err" "--digest needs a value"; assert_no_crash "$err"

rc=0; err="$(cd "$TMP" && "$RELAY" load --dir 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "2"; assert_contains "$err" "--dir needs a value"; assert_no_crash "$err"

# --- flag-eats-flag: a value flag immediately followed by another flag is rejected, not consumed ---
rc=0; err="$(cd "$TMP" && "$RELAY" knowledge add --fact --ttl --id foo body 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "2"; assert_contains "$err" "--ttl needs a value"; assert_no_crash "$err"

pass "knowledge missing/flag-shaped option value: clean usage error across all value flags, no set -u crash"
