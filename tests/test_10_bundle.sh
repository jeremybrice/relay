#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"
( cd "$SRC" && bash bundle.sh )
assert_file "$SRC/dist/install.sh"

# the bundled installer works with NO source tree (offline), in a fresh CC repo
TMP="$(mktemp -d)"; mkdir -p "$TMP/.claude"; ( cd "$TMP" && git init -q )
( cd "$TMP" && bash "$SRC/dist/install.sh" )
assert_file "$TMP/.relay/relay.sh"
( cd "$TMP" && printf '## Summary\nbundled ok\n' | .relay/relay.sh save --dir "$TMP/.session-log" --digest "d" )
assert_contains "$(cd "$TMP" && .relay/relay.sh load --dir "$TMP/.session-log")" "bundled ok"
pass "bundle → offline install works"
