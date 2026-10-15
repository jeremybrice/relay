#!/usr/bin/env bash
# smoke-compact.sh — contract test for relay knowledge compact/restore/empty-body guard.
# Runs against a throwaway --dir fixture; never touches the real .session-log.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RELAY="$HERE/../relay.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DATA="$TMP/.session-log"
mkdir -p "$DATA/knowledge/facts" "$DATA/knowledge/lessons"
fails=0
t() { # label expected actual
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; else printf 'FAIL - %s (want %s got %s)\n' "$1" "$2" "$3"; fails=$((fails+1)); fi
}

old="2000-01-01"
today="$(date +%F)"

lesson() { # file id seen last [body]
  printf -- '---\nid: %s\nkind: lesson\nseen: %s\nsessions: 1\nfirst_seen: %s\nlast_seen: %s\nsource: test\nstatus: active\ngraduated_to: null\n---\n%s\n' \
    "$2" "$3" "$4" "$4" "${5:-}" > "$1"
}
fact() { # file id confirmed last [body]
  printf -- '---\nid: %s\nkind: fact\nconfirmed: %s\nfirst_seen: %s\nlast_confirmed: %s\nttl: none\nsource: test\nstatus: active\n---\n%s\n' \
    "$2" "$3" "$4" "$4" "${5:-}" > "$1"
}

# --- fixture ---
lesson "$DATA/knowledge/lessons/empty-lesson.md"    empty-lesson   1 "$today" ""
fact   "$DATA/knowledge/facts/empty-fact.md"        empty-fact     1 "$today" ""
lesson "$DATA/knowledge/lessons/stale-seen1.md"     stale-seen1    1 "$old"    "body for stale-seen1"
lesson "$DATA/knowledge/lessons/fresh-seen1.md"     fresh-seen1    1 "$today"  "body for fresh-seen1"
lesson "$DATA/knowledge/lessons/old-reinforced.md"  old-reinforced 3 "$old"    "body for old-reinforced"
fact   "$DATA/knowledge/facts/keep-fact.md"         keep-fact      2 "$old"    "body for keep-fact"
# load only emits when a handoff exists (cmd_load early-returns without latest.md)
printf -- '---\ndate: %s\nsession: 1\ndigest: "fixture"\n---\nfixture handoff body\n' "$today" > "$DATA/latest.md"

# 1. empty-body add is rejected and writes nothing
if "$RELAY" knowledge add --lesson --id should-not-exist --dir "$DATA" >/dev/null 2>&1; then
  t "empty-body add rejected" "nonzero" "zero"
else
  t "empty-body add rejected" "nonzero" "nonzero"
fi
[ ! -f "$DATA/knowledge/lessons/should-not-exist.md" ] && r="absent" || r="present"
t "empty-body add wrote nothing" "absent" "$r"

# 2. compact dry run reports and changes nothing
out="$("$RELAY" knowledge compact --dir "$DATA" 2>/dev/null)" || true
echo "$out" | grep -q "would compact: lessons/empty-lesson" && r=yes || r=no; t "dry run flags empty lesson" yes "$r"
echo "$out" | grep -q "would compact: lessons/stale-seen1" && r=yes || r=no; t "dry run flags stale seen:1 lesson" yes "$r"
[ -f "$DATA/knowledge/lessons/empty-lesson.md" ] && r=yes || r=no; t "dry run changes nothing" yes "$r"

# 3. compact --yes moves entries to the right destinations
"$RELAY" knowledge compact --yes --dir "$DATA" >/dev/null 2>&1 || true
[ -f "$DATA/knowledge/lessons/superseded/empty-lesson.md" ] && r=yes || r=no; t "empty lesson -> superseded" yes "$r"
[ -f "$DATA/knowledge/facts/superseded/empty-fact.md" ] && r=yes || r=no; t "empty fact -> superseded" yes "$r"
[ -f "$DATA/knowledge/lessons/cold/stale-seen1.md" ] && r=yes || r=no; t "stale seen:1 lesson -> cold" yes "$r"
[ -f "$DATA/knowledge/lessons/fresh-seen1.md" ] && r=yes || r=no; t "fresh seen:1 lesson kept" yes "$r"
[ -f "$DATA/knowledge/lessons/old-reinforced.md" ] && r=yes || r=no; t "old reinforced lesson kept" yes "$r"
[ -f "$DATA/knowledge/facts/keep-fact.md" ] && r=yes || r=no; t "old fact kept (prune owns fact staleness)" yes "$r"
grep -q stale-seen1 "$DATA/knowledge/index.md" && r=no || r=yes; t "index excludes compacted entries" yes "$r"

# 4. caps: RELAY_LESSONS_MAX=2 with 3 active lessons -> lowest-ranked goes cold
lesson "$DATA/knowledge/lessons/cap-victim.md" cap-victim 1 "$today" "body for cap-victim"
RELAY_LESSONS_MAX=2 "$RELAY" knowledge compact --yes --dir "$DATA" >/dev/null 2>&1 || true
n="$(ls -1 "$DATA/knowledge/lessons"/*.md 2>/dev/null | wc -l | tr -d ' ')"
t "cap trims active lessons to RELAY_LESSONS_MAX" "2" "$n"
[ -f "$DATA/knowledge/lessons/old-reinforced.md" ] && r=yes || r=no; t "cap keeps highest-seen entry" yes "$r"
[ -f "$DATA/knowledge/lessons/cold/cap-victim.md" ] && r=yes || r=no; t "cap colds lowest-ranked entry" yes "$r"

# 5. restore returns a cold entry to active
"$RELAY" knowledge restore stale-seen1 --dir "$DATA" >/dev/null 2>&1 || true
[ -f "$DATA/knowledge/lessons/stale-seen1.md" ] && r=yes || r=no; t "restore returns cold entry" yes "$r"

# 6. loader output includes restored entries and excludes cold/superseded ones
out="$("$RELAY" load --dir "$DATA" 2>/dev/null)" || true
echo "$out" | grep -q "body for stale-seen1" && r=yes || r=no; t "loader shows restored entry" yes "$r"
echo "$out" | grep -q "body for cap-victim" && r=yes || r=no; t "loader hides cold entry" no "$r"

# 7. over-cap nudge appears in load output
out="$(RELAY_LESSONS_MAX=1 "$RELAY" load --dir "$DATA" 2>/dev/null)" || true
echo "$out" | grep -q "over cap" && r=yes || r=no; t "load nudges when over cap" yes "$r"

if [ "$fails" -gt 0 ]; then echo "SMOKE FAIL ($fails)"; exit 1; fi
echo "SMOKE OK"
