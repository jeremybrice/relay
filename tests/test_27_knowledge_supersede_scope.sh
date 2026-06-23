#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

# A lesson and an orphaned fact-conflict share the id "foo"; only the lesson exists as .md.
"$RELAY" knowledge add --lesson --id foo "a lesson body" --dir "$DIR" >/dev/null
mkdir -p "$DIR/knowledge/facts"
printf 'pending fact conflict body\n' > "$DIR/knowledge/facts/foo.conflict"

"$RELAY" knowledge supersede foo --dir "$DIR" >/dev/null
# the fact conflict must survive (we only superseded the lesson)
assert_file "$DIR/knowledge/facts/foo.conflict"

pass "knowledge supersede: superseding a lesson does not delete a same-id fact conflict"
