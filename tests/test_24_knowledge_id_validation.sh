#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

# Issue 2: symbol-only id is rejected (exit 2), nothing written.
assert_exit 2 "$RELAY" knowledge add --fact --id '@@@' "alpha body" --dir "$DIR"
[ -e "$DIR/knowledge/facts/.md" ] && { echo "FAIL: empty-slug dotfile was created"; exit 1; } || true

# Issue 4: two distinct long ids that share a 48-char prefix do NOT collide —
# they are rejected as too long rather than silently truncated/merged.
A="this-is-a-very-long-identifier-that-exceeds-forty-version-one"
B="this-is-a-very-long-identifier-that-exceeds-forty-version-two"
assert_exit 2 "$RELAY" knowledge add --fact --id "$A" "first fact about alpha" --dir "$DIR"
assert_exit 2 "$RELAY" knowledge add --fact --id "$B" "second fact about beta" --dir "$DIR"
# no truncated collision file exists
[ -e "$DIR/knowledge/facts/this-is-a-very-long-identifier-that-exceeds-fort.md" ] \
  && { echo "FAIL: over-length id was silently truncated"; exit 1; } || true

# Control: a normal id still works and stores its full slug verbatim.
"$RELAY" knowledge add --fact --id deploy-via-release "ships via release.sh" --dir "$DIR" >/dev/null
assert_file "$DIR/knowledge/facts/deploy-via-release.md"

pass "knowledge id validation: empty rejected, over-length rejected, normal id stored verbatim"
