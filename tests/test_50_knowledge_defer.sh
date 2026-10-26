#!/usr/bin/env bash
# test_50_knowledge_defer.sh: "not yet" defers a ready lesson until it is re-asserted on a later
# day; the graduation-ready notice now points at the next session start instead of an offer.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
L="$DIR/knowledge/lessons"
setfm() { sed -i.bak "s/^$2: .*/$2: $3/" "$1" && rm -f "$1.bak"; }

"$RELAY" knowledge add --lesson --id x "when X, do Y, because Z" --dir "$DIR" >/dev/null
setfm "$L/x.md" sessions 3
out="$("$RELAY" knowledge defer x --dir "$DIR")"
assert_eq "$out" "deferred: x (now sessions:3; comes back once re-asserted on a later day)"
assert_contains "$(cat "$L/x.md")" "deferred_at: 3"

assert_exit 1 "$RELAY" knowledge defer missing --dir "$DIR"
err="$("$RELAY" knowledge defer missing --dir "$DIR" 2>&1 || true)"
assert_contains "$err" "relay: no active lesson: missing"

# same-day re-assertion: sessions unchanged, still deferred, no ready notice
out="$("$RELAY" knowledge add --lesson --id x "when X, do Y, because Z" --dir "$DIR")"
[ -z "$(printf '%s' "$out" | grep -F 'graduation-ready' || true)" ] || { echo "FAIL: deferred lesson announced ready"; exit 1; }

# re-asserted on a later day: sessions 4 > deferred_at 3, ready again
setfm "$L/x.md" last_seen 2000-01-01
out="$("$RELAY" knowledge add --lesson --id x "when X, do Y, because Z" --dir "$DIR")"
assert_contains "$out" "→ graduation-ready (sessions:4 ≥ 3): it will be asked about at the next session start"

# a never-deferred lesson reaching 3 gets the same wording
"$RELAY" knowledge add --lesson --id y "when A, do B" --dir "$DIR" >/dev/null
setfm "$L/y.md" sessions 2; setfm "$L/y.md" last_seen 2000-01-01
out="$("$RELAY" knowledge add --lesson --id y "when A, do B" --dir "$DIR")"
assert_contains "$out" "→ graduation-ready (sessions:3 ≥ 3): it will be asked about at the next session start"

[ -z "$(grep -F "propose 'relay knowledge graduate" "$RELAY" || true)" ] || { echo "FAIL: old offer wording remains"; exit 1; }
pass "knowledge defer: not-yet waits for a later-day re-assertion"
