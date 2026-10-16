#!/usr/bin/env bash
# test_43_format_guard.sh: an older relay.sh never writes a store laid out by a newer one.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

# an unstamped store (every install before this change) is stamped on first write, not refused
printf '## Summary\nfirst\n' | "$RELAY" save --dir "$DIR" --digest d
assert_eq "$(cat "$DIR/.relay-format")" "2"

# a store from a newer Relay: writes refused, nothing changed, no lock left behind
echo 99 > "$DIR/.relay-format"
before="$(cat "$DIR/latest.md")"
rc=0; err="$(printf 'second\n' | "$RELAY" save --dir "$DIR" --digest d2 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "1"; assert_contains "$err" "format 99"; assert_contains "$err" "install.sh --detect"
assert_eq "$(cat "$DIR/latest.md")" "$before"
[ ! -d "$DIR/.lock" ] || { echo "FAIL: lock left behind"; exit 1; }
rc=0; "$RELAY" knowledge add --fact --id f "x y z" --dir "$DIR" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1"
[ ! -e "$DIR/knowledge/facts/f.md" ] || { echo "FAIL: knowledge written into a newer store"; exit 1; }

# load is read-only: still works, and warns
out="$("$RELAY" load --dir "$DIR")"
assert_contains "$out" "newer Relay"; assert_contains "$out" "first"

# a garbage stamp counts as unstamped and is rewritten
echo junk > "$DIR/.relay-format"
printf 'third\n' | "$RELAY" save --dir "$DIR" --digest d3
assert_eq "$(cat "$DIR/.relay-format")" "2"
pass "format guard: stamp on write, refuse newer stores, load warns"
