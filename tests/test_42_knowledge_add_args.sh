#!/usr/bin/env bash
# test_42_knowledge_add_args.sh: knowledge add never stores a flag or a truncated body.
# Regression: `--body "…"` stored "--body" as the body (11 entries lost across installs).
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

# unknown flag: rejected, nothing written
rc=0; err="$("$RELAY" knowledge add --lesson --id l1 --body "real text" --dir "$DIR" 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "2"; assert_contains "$err" "unknown option for knowledge add: --body"
[ ! -e "$DIR/knowledge/lessons/l1.md" ] || { echo "FAIL: wrote despite unknown flag"; exit 1; }

# unquoted body (several positionals): rejected, not cut to the first word
rc=0; err="$("$RELAY" knowledge add --fact --id f1 deploys ship via release --dir "$DIR" 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "2"; assert_contains "$err" "one body argument"
[ ! -e "$DIR/knowledge/facts/f1.md" ] || { echo "FAIL: wrote a truncated body"; exit 1; }

# stdin body plus a positional body: rejected
rc=0; err="$(printf 'x\n' | "$RELAY" knowledge add --fact --id f2 - "also" --dir "$DIR" 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "2"; assert_contains "$err" "one body argument"

# a body that merely starts with -- (contains spaces) is still a body
"$RELAY" knowledge add --fact --id no-verify "--no-verify is banned in this repo" --dir "$DIR" >/dev/null
assert_contains "$(cat "$DIR/knowledge/facts/no-verify.md")" "--no-verify is banned"

# "-" reads the body from stdin, so apostrophes need no shell escaping
printf "Don't run npm publish; it's release.sh only\n" \
  | "$RELAY" knowledge add --fact --id stdin-fact - --dir "$DIR" >/dev/null
assert_contains "$(cat "$DIR/knowledge/facts/stdin-fact.md")" "Don't run npm publish; it's release.sh only"

# empty stdin is still an empty body
rc=0; printf '' | "$RELAY" knowledge add --fact --id empty - --dir "$DIR" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2"

# compact sweeps flag-only bodies left behind by the old bug
mkdir -p "$DIR/knowledge/lessons"
printf -- '---\nid: lost\nkind: lesson\nseen: 1\nsessions: 1\nfirst_seen: 2026-01-01\nlast_seen: 2026-01-01\nsource: x\nstatus: active\ngraduated_to: null\n---\n--body\n' \
  > "$DIR/knowledge/lessons/lost.md"
out="$("$RELAY" knowledge compact --yes --dir "$DIR")"
assert_contains "$out" "lessons/lost"
assert_contains "$out" "flag-only"
assert_file "$DIR/knowledge/lessons/superseded/lost.md"
pass "knowledge add: unknown flags and split bodies rejected, '-' reads stdin, flag-only bodies swept"
