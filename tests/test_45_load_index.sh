#!/usr/bin/env bash
# test_45_load_index.sh: load names every entry by id; full text in rank order up to the
# word budget, the rest listed by id, never silently dropped.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

printf '## Summary\nh\n' | "$RELAY" save --dir "$DIR" --digest d
"$RELAY" knowledge add --fact --id big-fact "alpha beta gamma delta epsilon zeta eta theta" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact --id small-fact "one two" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact --id small-fact "one two" --dir "$DIR" >/dev/null      # confirmed:2 ranks first
"$RELAY" knowledge add --fact --id tabbed "$(printf 'col1\tcol2 value')" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --lesson --id often "when X prefer Y because Z" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --lesson --id often "when X prefer Y because Z" --dir "$DIR" >/dev/null   # seen:2
"$RELAY" knowledge add --lesson --id once "when P prefer Q" --dir "$DIR" >/dev/null

# under budget: every entry in full, each with its id
out="$("$RELAY" load --dir "$DIR")"
assert_contains "$out" '- `small-fact`: one two (confirmed:2)'
assert_contains "$out" '- `often`: when X prefer Y because Z (seen:2, sessions:1)'
assert_contains "$out" '- `tabbed`: col1 col2 value (confirmed:1)'
assert_contains "$out" "re-assert it by id"
[ -z "$(printf '%s' "$out" | grep -F 'More (' || true)" ] || { echo "FAIL: More line under budget"; exit 1; }

# over budget: ranked prefix in full, the rest by id; the first entry always shows
out="$(RELAY_FACTS_CAP=5 RELAY_LESSONS_CAP=7 "$RELAY" load --dir "$DIR")"
assert_contains "$out" '- `small-fact`: one two (confirmed:2)'
assert_contains "$out" "⚠ 1 of 3 facts shown in full"
assert_match "$out" '^More \(2, by id; open with: relay knowledge why <id>\): (big-fact, tabbed|tabbed, big-fact)$'
[ -z "$(printf '%s' "$out" | grep -F 'alpha beta' || true)" ] || { echo "FAIL: over-budget body still in full"; exit 1; }
assert_contains "$out" '- `often`: when X prefer Y because Z'
assert_contains "$out" "⚠ 1 of 2 lessons shown in full"
assert_contains "$out" "More (1, by id; open with: relay knowledge why <id>): once"

# a listed id opens with why
assert_contains "$("$RELAY" knowledge why big-fact --dir "$DIR")" "alpha beta"
pass "load index: ids on every entry, full text to budget, rest by id"
