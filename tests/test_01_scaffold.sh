#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
. ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"

setup_tmp
# unknown command exits 2
assert_exit 2 "$RELAY" bogus
# usage text mentions load and save
out="$("$RELAY" bogus 2>&1 || true)"
assert_contains "$out" "load"
assert_contains "$out" "save"
pass "scaffold"
