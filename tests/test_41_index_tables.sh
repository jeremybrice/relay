#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
today="$(date +%F)"
mkdir -p "$DIR"

# a legacy line-format index is migrated to the table on the next save
cat > "$DIR/index.md" <<'EOF'
# Session index — last 10 days
- 2026-01-02 — Older work; chose a | b → history/2026-01-02.md
- 2026-01-01 — Oldest work → history/2026-01-01.md
EOF
printf '## Summary\nx\n' | "$RELAY" save --dir "$DIR" --digest "New | piped digest"
idx="$(cat "$DIR/index.md")"
assert_match "$idx" "^# Session index \\(last 10 days\\)$"
assert_match "$idx" "^\\| Date +\\| Summary +\\| History +\\|$"
assert_match "$idx" "^\\| $today \\| New / piped digest +\\| \\[$today\\]\\(history/$today\\.md\\) \\|$"
assert_match "$idx" "^\\| 2026-01-02 \\| Older work; chose a / b +\\| \\[2026-01-02\\]\\(history/2026-01-02\\.md\\) \\|$"
assert_match "$idx" "^\\| 2026-01-01 \\| Oldest work +\\|"
# newest first, no legacy lines left, every row has exactly 4 pipes (3 columns)
assert_eq "$(grep '^| 20' "$DIR/index.md" | head -n1 | cut -c3-12)" "$today"
assert_eq "$(grep -c '^- ' "$DIR/index.md" || true)" "0"
assert_eq "$(grep '^|' "$DIR/index.md" | awk -F'|' 'NF!=5' | wc -l | tr -d ' ')" "0"
# columns are padded to equal width
assert_eq "$(grep '^|' "$DIR/index.md" | awk '{print length($0)}' | sort -u | wc -l | tr -d ' ')" "1"

# re-saving round-trips the table (no drift) and the window caps rows
for d in 03 04 05 06 07 08 09 10 11 12; do
  printf '| 2026-01-%s | filler %s | [2026-01-%s](history/2026-01-%s.md) |\n' "$d" "$d" "$d" "$d" >> "$DIR/index.md"
done
printf '## Summary\ny\n' | "$RELAY" save --dir "$DIR" --digest "Second
line"
assert_eq "$(grep -c '^| 20' "$DIR/index.md")" "10"
assert_eq "$(grep -c "^| $today " "$DIR/index.md")" "1"
assert_match "$(cat "$DIR/index.md")" "^\\| $today \\| Second line +\\|"
pass "session index: table layout, legacy migration, pipe/newline sanitizing, window"
