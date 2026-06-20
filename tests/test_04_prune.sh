#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
mkdir -p "$DIR/history"

# Seed 11 distinct past days directly (bypassing date), then prune via a final save.
for d in 01 02 03 04 05 06 07 08 09 10 11; do
  printf -- '---\ndate: 2026-05-%s\nsession: 1\ndigest: "day %s"\n---\n\n## Summary\nx\n' "$d" "$d" \
    > "$DIR/history/2026-05-$d.md"
done
printf '## Summary\nnewest\n' | "$RELAY" save --dir "$DIR" --digest "newest"

# 11 seeded + 1 new = 12; prune keeps 10
n="$(ls -1 "$DIR/history"/*.md | wc -l | tr -d ' ')"
assert_eq "$n" "10"
# oldest (2026-05-01) is gone; newest day present
[ -f "$DIR/history/2026-05-01.md" ] && { echo "FAIL: oldest not pruned"; exit 1; }
assert_file "$DIR/history/$(date +%F).md"
pass "prune to 10"
