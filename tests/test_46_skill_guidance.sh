#!/usr/bin/env bash
# test_46_skill_guidance.sh: every harness's save/learn/compact text uses quote-safe stdin
# bodies, tells the agent to re-assert loaded lessons by id, and defines a lesson narrowly.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)/adapters"

for f in "$SRC/skills/session-save/SKILL.md" "$SRC/codex/skills/session-save/SKILL.md" "$SRC/opencode/commands/session-save.md"; do
  t="$(cat "$f")"
  assert_contains "$t" "<<'RELAY_HANDOFF'"
  assert_contains "$t" "re-assert it"
  assert_contains "$t" "SAME id"
  assert_contains "$t" "Carry forward"
  assert_contains "$t" "knowledge why <id>"
  [ -z "$(printf '%s' "$t" | grep -F "printf '%s\\n' '" || true)" ] || { echo "FAIL: $f still uses single-quoted printf"; exit 1; }
done
for f in "$SRC/skills/relay-learn/SKILL.md" "$SRC/codex/skills/relay-learn/SKILL.md" "$SRC/opencode/commands/relay-learn.md"; do
  t="$(cat "$f")"
  assert_contains "$t" "--lesson --near"
  assert_contains "$t" "it is a fact, not a lesson"
  assert_contains "$t" "<<'RELAY_BODY'"
  assert_contains "$t" "anything else is rejected"
done
for f in "$SRC/skills/relay-compact/SKILL.md" "$SRC/codex/skills/relay-compact/SKILL.md" "$SRC/opencode/commands/relay-compact.md"; do
  t="$(cat "$f")"
  assert_contains "$t" "<<'RELAY_BODY'"
  [ -z "$(printf '%s' "$t" | grep -F "'<rewritten body>'" || true)" ] || { echo "FAIL: $f still single-quotes the body"; exit 1; }
done
# save reads the user's turns first (harnesses with a transcript); graduation moves to session start
for f in "$SRC/skills/session-save/SKILL.md" "$SRC/codex/skills/session-save/SKILL.md"; do
  t="$(cat "$f")"
  assert_contains "$t" 'relay.sh" turns'
  assert_contains "$t" "Read your turns first."
done
assert_contains "$(cat "$SRC/skills/session-save/SKILL.md")" "--harness auto"
assert_contains "$(cat "$SRC/codex/skills/session-save/SKILL.md")" "--harness codex"
for f in "$SRC"/skills/*/SKILL.md "$SRC"/codex/skills/*/SKILL.md "$SRC"/opencode/commands/*.md "$SRC"/*/AGENTS.relay.md; do
  t="$(cat "$f")"
  for old in "offer graduation in one line" "surface any graduation-ready lesson" "graduation only when prompted" "offer (one line) to run"; do
    [ -z "$(printf '%s' "$t" | grep -F -- "$old" || true)" ] || { echo "FAIL: $f still offers graduation at wrap-up"; exit 1; }
  done
done
for f in "$SRC"/*/AGENTS.relay.md; do assert_contains "$(cat "$f")" "asked about at session start"; done
for f in "$SRC/skills/relay-compact/SKILL.md" "$SRC/codex/skills/relay-compact/SKILL.md" "$SRC/opencode/commands/relay-compact.md"; do
  assert_contains "$(cat "$f")" "--rule -"
done
pass "skills: stdin bodies, lesson re-assertion by id, sharp lesson definition, turns first, graduation at start"
