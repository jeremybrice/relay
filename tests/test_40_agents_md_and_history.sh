#!/usr/bin/env bash
# test_40_agents_md_and_history.sh — Claude Code's block lands in AGENTS.md (an
# older CLAUDE.md block is moved, user text kept); every adapter and the load
# footer tell the agent to open earlier history files; graduated lessons target
# AGENTS.md unless CLAUDE.md already holds them.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"

# fresh install → AGENTS.md, no CLAUDE.md created
TMP="$(mktemp -d)"; ( cd "$TMP" && git init -q )
( cd "$TMP" && bash "$SRC/install.sh" --clis claude --from "$SRC" </dev/null >/dev/null )
assert_contains "$(cat "$TMP/AGENTS.md")" "(Claude Code)"
[ ! -e "$TMP/CLAUDE.md" ] || { echo "FAIL: fresh install created CLAUDE.md"; exit 1; }
pass "cc block installs into AGENTS.md"

# upgrade: old block leaves CLAUDE.md, user text stays, block appears once in AGENTS.md
TMP2="$(mktemp -d)"; ( cd "$TMP2" && git init -q && mkdir .claude )
cat > "$TMP2/CLAUDE.md" <<'MD'
# My repo
keep me

# >>> relay >>>
<!-- adapters/claude-code/CLAUDE.relay.md -->
## Relay — session handoff (Claude Code)
old wording
# <<< relay <<<
MD
( cd "$TMP2" && bash "$SRC/install.sh" --clis claude --from "$SRC" </dev/null >/dev/null )
c="$(cat "$TMP2/CLAUDE.md")"
assert_contains "$c" "keep me"
printf '%s' "$c" | grep -qF "old wording" && { echo "FAIL: old CLAUDE.md block kept"; exit 1; }
printf '%s' "$c" | grep -qF ">>> relay >>>" && { echo "FAIL: relay marker left in CLAUDE.md"; exit 1; }
( cd "$TMP2" && bash "$SRC/install.sh" --clis claude --from "$SRC" </dev/null >/dev/null )
assert_eq "$(grep -c 'adapters/claude-code/AGENTS.relay.md' "$TMP2/AGENTS.md")" "1"
pass "old CLAUDE.md block migrates to AGENTS.md"

# a CLAUDE.md that held only the relay block is removed, not left empty
TMP3="$(mktemp -d)"; ( cd "$TMP3" && git init -q )
printf '\n# >>> relay >>>\n<!-- adapters/claude-code/CLAUDE.relay.md -->\nold\n# <<< relay <<<\n' > "$TMP3/CLAUDE.md"
( cd "$TMP3" && bash "$SRC/install.sh" --clis claude --from "$SRC" </dev/null >/dev/null )
[ ! -e "$TMP3/CLAUDE.md" ] || { echo "FAIL: empty CLAUDE.md left behind"; exit 1; }
pass "relay-only CLAUDE.md removed"

# oldest installs: an "(L2)" block with no adapter header comment is migrated too
TMP7="$(mktemp -d)"; ( cd "$TMP7" && git init -q )
printf '# Mine

# >>> relay >>>
## Relay — session handoff (L2)
old
# <<< relay <<<
' > "$TMP7/CLAUDE.md"
( cd "$TMP7" && bash "$SRC/install.sh" --clis claude --from "$SRC" </dev/null >/dev/null )
grep -qF "(L2)" "$TMP7/CLAUDE.md" && { echo "FAIL: L2 block kept"; exit 1; }
assert_contains "$(cat "$TMP7/CLAUDE.md")" "# Mine"
pass "header-less (L2) CLAUDE.md block migrated"

# every adapter block + the load footer point at earlier history files
for a in claude-code codex cursor grok opencode; do
  assert_contains "$(cat "$SRC/adapters/$a/AGENTS.relay.md")" "history/<date>.md"
done
TMP4="$(mktemp -d)"
( cd "$TMP4" && printf '## Summary\nx\n' | "$SRC/relay.sh" save --dir "$TMP4/.session-log" --digest d >/dev/null )
out="$("$SRC/relay.sh" load --dir "$TMP4/.session-log")"
assert_contains "$out" "If the task touches work from an earlier day in the index, open .session-log/history/<date>.md"
pass "adapters + load footer direct agents to earlier history"

# graduate target: AGENTS.md by default; CLAUDE.md stays sticky once it holds graduated rules
unset RELAY_INSTRUCTION_FILE || true
TMP5="$(mktemp -d)"; D5="$TMP5/.session-log"
( cd "$TMP5" && touch CLAUDE.md AGENTS.md \
  && "$SRC/relay.sh" knowledge add --lesson --id a-one "Lesson one." --dir "$D5" >/dev/null \
  && "$SRC/relay.sh" knowledge graduate a-one --dir "$D5" >/dev/null 2>&1 )
assert_contains "$(cat "$TMP5/AGENTS.md")" "<!-- relay:learned:a-one -->"
TMP6="$(mktemp -d)"; D6="$TMP6/.session-log"
printf '<!-- relay:learned -->\n<!-- relay:learned:old -->\nold rule\n<!-- /relay:learned:old -->\n<!-- /relay:learned -->\n' > "$TMP6/CLAUDE.md"
touch "$TMP6/AGENTS.md"
( cd "$TMP6" && "$SRC/relay.sh" knowledge add --lesson --id b-two "Lesson two." --dir "$D6" >/dev/null \
  && "$SRC/relay.sh" knowledge graduate b-two --dir "$D6" >/dev/null 2>&1 )
assert_contains "$(cat "$TMP6/CLAUDE.md")" "<!-- relay:learned:b-two -->"
pass "graduate targets AGENTS.md, CLAUDE.md sticky when it already holds rules"
