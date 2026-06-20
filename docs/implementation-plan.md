# Relay — Session Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Relay — a portable, cross-harness session-handoff tool that lets agents hand off to each other day-to-day across a rolling 10-day window, installable into any repo via a single embedded `install.sh`.

**Architecture:** A deterministic bash helper (`relay.sh`) owns every file operation (save/load/rotate/prune) under a portable advisory lock; the agent only authors prose. Two thin adapters wire `relay load` / `relay save` into Claude Code and Codex via their SessionStart hooks and a save command/skill. An installer lays the tool down per-repo and gitignores the handoff data; a bundler concatenates everything into one shareable `install.sh`.

**Tech Stack:** Bash (portable across macOS/BSD + Linux/GNU), plain-bash test scripts (zero dependency), git. Install-time JSON merge uses `jq` → `python3` → manual fallback.

**Design spec:** `docs/design-spec.md`

## Global Constraints

Every task's requirements implicitly include these:

- **Zero runtime dependencies.** `relay.sh` and the adapter hooks use only bash + coreutils present on stock macOS and Linux. No `jq`/`python3` at runtime (install-time only).
- **Portable bash.** No `flock` (absent on macOS) — use the `mkdir` advisory lock. No `sed -i` (BSD/GNU differ) — use temp-file + `mv`. Date→epoch via `to_epoch()` (GNU `date -d` with BSD `date -j` fallback). Portable `mktemp`.
- **Agent authors prose only.** `relay.sh` owns all byte-level ops: write, append, rotate, prune, lock, frontmatter generation. Pruning-to-10 and appends are never left to the LLM.
- **Window = the 10 most-recent dated files.** `index.md` carries exactly one line per day.
- **Handoff = frontmatter (`date`, `session`, `digest`) + 6 sections** (`## Summary`, `## Changed`, `## Decisions`, `## Next`, `## Watch out`, `## Open questions`).
- **Load surfaces staleness** (a `⚠` flag when `latest.md` is older than 3 days) and soft-caps output at ~800 words.
- **Locking is wait-your-turn**, scoped to the brief write critical section, with stale-break on dead PID or 30s timeout.
- **Two harnesses, symmetric:** Claude Code (stdout→context, `/session-save`) and Codex (`systemMessage` JSON, `$session-save`).
- **`.session-log/` is gitignored and local; `.relay/` (the tool) is committed.** Deliverable is one embedded `install.sh`.

### Spec reconciliation notes (intent preserved, mechanism adjusted)

1. **§10 `flock` → portable `mkdir` lock.** macOS lacks `flock(1)`. The `mkdir` lock keeps wait-your-turn semantics; stale-break (dead PID / 30s) replaces flock's auto-release-on-death.
2. **§12 settings.json wiring** needs a JSON-aware merge → installer tries `jq`, then `python3`, then prints the exact JSON block to paste. Install-time only.
3. **Codex `systemMessage`** auto-injection is verified-by-docs, not yet verified-against-running-Codex → Task 8 includes a manual smoke-test; the AGENTS.md instruction-chain is the guaranteed fallback.

---

## File Structure

The Relay **source repo** (developed standalone, then committed into target repos as `.relay/`):

```
relay.sh                                  # Core: load | save | rotate | prune | lock
install.sh                                # Installer (dev template; bundler embeds files into the released copy)
bundle.sh                                 # Release step: sources → single embedded install.sh
README.md                                 # curl one-liner + usage
adapters/
  claude-code/
    relay-session-start.sh                # SessionStart hook → relay load (stdout→context)
    commands/session-save.md              # /session-save command (L1)
    CLAUDE.relay.md                        # L2 wrap-up instruction block (appended to CLAUDE.md)
  codex/
    relay-session-start.sh                # SessionStart hook → relay load --format codex (systemMessage JSON)
    skills/session-save/SKILL.md          # $session-save skill (L1)
    AGENTS.relay.md                        # L2 wrap-up instruction block (appended to AGENTS.md)
    hooks.relay.toml                       # config.toml [hooks] SessionStart snippet
tests/
  helper.sh                               # tiny zero-dep assert library
  test_01_scaffold.sh … test_10_bundle.sh
```

After install, a **target repo** contains: committed `.relay/` (the above tool files) + wiring in `.claude/settings.json` / `.codex/config.toml` + appended `CLAUDE.md`/`AGENTS.md` blocks; gitignored `.session-log/` (data).

---

## Task 1: Scaffold, dispatcher, and test harness

**Files:**
- Create: `relay.sh`
- Create: `tests/helper.sh`
- Create: `tests/test_01_scaffold.sh`

**Interfaces:**
- Produces: `relay.sh` executable with `main "$@"` dispatch supporting `load|save`, flags `--dir DIR`, `--format text|codex`, `--digest STR`. Data dir resolves to `${RELAY_DIR:-$PWD/.session-log}` or `--dir`. Unknown command → exit 2 + usage.
- Produces (test API): `assert_eq a b`, `assert_contains haystack needle`, `assert_file path`, `assert_exit code cmd...`, `setup_tmp` (sets `$TMP`, `$DIR`), `pass`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_01_scaffold.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
. ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"

setup_tmp
# unknown command exits 2
assert_exit 2 "$RELAY" bogus
# usage text mentions load and save
out="$("$RELAY" bogus 2>&1 || true)"
assert_contains "$out" "load"
assert_contains "$out" "save"
pass "scaffold"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_01_scaffold.sh`
Expected: FAIL (`relay.sh` and `helper.sh` do not exist yet — "No such file").

- [ ] **Step 3: Write the test helper**

```bash
# tests/helper.sh — zero-dependency assert library
assert_eq() { [ "$1" = "$2" ] || { echo "FAIL: expected [$2], got [$1]"; exit 1; }; }
assert_contains() { printf '%s' "$1" | grep -qF -- "$2" || { echo "FAIL: [$1] missing [$2]"; exit 1; }; }
assert_file() { [ -f "$1" ] || { echo "FAIL: missing file $1"; exit 1; }; }
assert_exit() { local want="$1"; shift; local got=0; "$@" >/dev/null 2>&1 || got=$?; [ "$got" = "$want" ] || { echo "FAIL: exit $got != $want for: $*"; exit 1; }; }
setup_tmp() { TMP="$(mktemp -d)"; DIR="$TMP/.session-log"; }
pass() { echo "PASS: ${1:-test}"; }
```

- [ ] **Step 4: Write the minimal `relay.sh`**

```bash
#!/usr/bin/env bash
# relay.sh — deterministic session-handoff helper
set -euo pipefail

RELAY_WINDOW=10
RELAY_STALE_DAYS=3
RELAY_WORD_CAP=800
RELAY_LOCK_TIMEOUT=30

usage() {
  echo "usage: relay.sh {load|save} [--dir DIR] [--format text|codex] [--digest STR]" >&2
}

main() {
  local cmd="${1:-}"; [ $# -gt 0 ] && shift || true
  DATA="${RELAY_DIR:-$PWD/.session-log}"
  local format="text" digest=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) DATA="$2"; shift 2;;
      --format) format="$2"; shift 2;;
      --digest) digest="$2"; shift 2;;
      *) echo "relay: unknown arg $1" >&2; usage; return 2;;
    esac
  done
  case "$cmd" in
    load) cmd_load "$format";;
    save) cmd_save "$digest";;
    *) usage; return 2;;
  esac
}

cmd_load() { return 0; }   # filled in Task 6
cmd_save() { return 0; }   # filled in Tasks 2-5

main "$@"
```

- [ ] **Step 5: Make executable, run test to verify it passes**

Run: `chmod +x relay.sh && bash tests/test_01_scaffold.sh`
Expected: `PASS: scaffold`

- [ ] **Step 6: Commit**

```bash
git add relay.sh tests/helper.sh tests/test_01_scaffold.sh
git commit -m "feat(relay): scaffold dispatcher + zero-dep test harness"
```

---

## Task 2: `relay save` — first session of a day

**Files:**
- Modify: `relay.sh` (`cmd_save`, `to_epoch`)
- Create: `tests/test_02_save_first.sh`

**Interfaces:**
- Consumes: dispatcher from Task 1; `$DATA` (data dir), `$1` (digest); body on stdin.
- Produces: `cmd_save DIGEST` reads the 6-section body from stdin and creates `$DATA/history/<today>.md`, `$DATA/latest.md` (frontmatter `date`/`session: 1`/`digest` + body), and `$DATA/index.md` (header + one line). `to_epoch YYYY-MM-DD` → epoch seconds (used later).

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_02_save_first.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
today="$(date +%F)"

printf '## Summary\nDid a thing in app.ts\n' | "$RELAY" save --dir "$DIR" --digest "Did a thing"

assert_file "$DIR/history/$today.md"
assert_file "$DIR/latest.md"
assert_file "$DIR/index.md"
assert_contains "$(cat "$DIR/latest.md")" "session: 1"
assert_contains "$(cat "$DIR/latest.md")" "Did a thing in app.ts"
assert_contains "$(cat "$DIR/index.md")" "- $today — Did a thing → history/$today.md"
pass "save first session"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_02_save_first.sh`
Expected: FAIL (no files created — `cmd_save` is a stub).

- [ ] **Step 3: Implement `to_epoch` and `cmd_save` (first-session path + index)**

Replace the `cmd_save() { return 0; }` stub and add `to_epoch` above `main`:

```bash
to_epoch() { date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null; }

_index_update() {
  local date="$1" digest="$2" idx="$DATA/index.md" tmp
  tmp="$(mktemp)"
  printf '# Session index — last %s days\n' "$RELAY_WINDOW" > "$tmp"
  printf -- '- %s — %s → history/%s.md\n' "$date" "$digest" "$date" >> "$tmp"
  if [ -f "$idx" ]; then
    grep '^- ' "$idx" 2>/dev/null | grep -v "^- $date " >> "$tmp" || true
  fi
  { sed -n '1p' "$tmp"; grep '^- ' "$tmp" | head -n "$RELAY_WINDOW"; } > "$idx"
  rm -f "$tmp"
}

cmd_save() {
  local digest="$1" body date today fm handoff n=0
  body="$(cat)"
  date="$(date +%F)"
  mkdir -p "$DATA/history"
  today="$DATA/history/$date.md"
  if [ -f "$today" ]; then
    n=$(grep -c '^date:' "$today" 2>/dev/null) || n=0
  fi
  local sess=$(( n + 1 ))
  fm="$(printf -- '---\ndate: %s\nsession: %s\ndigest: "%s"\n---' "$date" "$sess" "$digest")"
  handoff="$(printf '%s\n\n%s' "$fm" "$body")"
  if [ -f "$today" ]; then
    printf '\n\n---\n\n%s\n' "$handoff" >> "$today"
  else
    printf '%s\n' "$handoff" > "$today"
  fi
  printf '%s\n' "$handoff" > "$DATA/latest.md"
  _index_update "$date" "$digest"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_02_save_first.sh`
Expected: `PASS: save first session`

- [ ] **Step 5: Commit**

```bash
git add relay.sh tests/test_02_save_first.sh
git commit -m "feat(relay): save first session of a day (history + latest + index)"
```

---

## Task 3: `relay save` — same-day append and index de-dup

**Files:**
- Modify: `tests/` only (behavior already implemented in Task 2 — this task verifies and hardens it)
- Create: `tests/test_03_same_day.sh`

**Interfaces:**
- Consumes: `cmd_save` from Task 2.
- Produces: guarantee that a second same-day save appends `session: 2` to the day's history file, overwrites `latest.md` with the newest session, and the day appears **once** in `index.md`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_03_same_day.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
today="$(date +%F)"

printf '## Summary\nfirst\n'  | "$RELAY" save --dir "$DIR" --digest "first digest"
printf '## Summary\nsecond\n' | "$RELAY" save --dir "$DIR" --digest "second digest"

# history holds both sessions
hist="$(cat "$DIR/history/$today.md")"
assert_contains "$hist" "session: 1"
assert_contains "$hist" "session: 2"
# latest = newest
assert_contains "$(cat "$DIR/latest.md")" "second"
assert_contains "$(cat "$DIR/latest.md")" "session: 2"
# index shows the day exactly once, with the newest digest
count="$(grep -c "^- $today " "$DIR/index.md")"
assert_eq "$count" "1"
assert_contains "$(cat "$DIR/index.md")" "second digest"
pass "same-day append + index dedup"
```

- [ ] **Step 2: Run test to verify it passes (behavior built in Task 2)**

Run: `bash tests/test_03_same_day.sh`
Expected: `PASS: same-day append + index dedup`

If it FAILS on the index count, the `grep -v "^- $date "` filter in `_index_update` is wrong — verify the trailing space matches the line format `- <date> — …`.

- [ ] **Step 3: Commit**

```bash
git add tests/test_03_same_day.sh
git commit -m "test(relay): cover same-day append + index dedup"
```

---

## Task 4: `relay save` — rolling-window prune to 10 files

**Files:**
- Modify: `relay.sh` (add `_prune`, call it from `cmd_save`)
- Create: `tests/test_04_prune.sh`

**Interfaces:**
- Consumes: `cmd_save`.
- Produces: `_prune` deletes all but the 10 most-recent dated files in `$DATA/history`; `index.md` already caps at 10 lines (Task 2).

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_04_prune.sh
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_04_prune.sh`
Expected: FAIL (`n` = 12 — pruning not implemented yet).

- [ ] **Step 3: Implement `_prune` and call it**

Add the function near `_index_update`:

```bash
_prune() {
  local n=0 f
  for f in $(ls -1 "$DATA/history"/*.md 2>/dev/null | sort -r); do
    n=$((n+1))
    [ "$n" -gt "$RELAY_WINDOW" ] && rm -f "$f"
  done
  return 0
}
```

Then add `_prune` as the last line of `cmd_save` (after `_index_update "$date" "$digest"`):

```bash
  _index_update "$date" "$digest"
  _prune
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_04_prune.sh`
Expected: `PASS: prune to 10`

- [ ] **Step 5: Commit**

```bash
git add relay.sh tests/test_04_prune.sh
git commit -m "feat(relay): prune history to the 10 most-recent dated files"
```

---

## Task 5: Portable wait-your-turn locking

**Files:**
- Modify: `relay.sh` (add `_lock`/`_unlock`, wrap `cmd_save`'s critical section)
- Create: `tests/test_05_lock.sh`

**Interfaces:**
- Consumes: `cmd_save`, `$DATA`.
- Produces: `_lock` acquires `$DATA/.lock` (mkdir), waits if held, breaks a stale lock (dead PID or >30s), writes `PID\nepoch` to `.lock/info`, sets an EXIT trap. `_unlock` removes it. The save's write/append/index/prune run only while held.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_05_lock.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
mkdir -p "$DIR"

# (a) a STALE lock (dead PID) must be broken, not block forever
mkdir -p "$DIR/.lock"; printf '999999\n1\n' > "$DIR/.lock/info"   # PID unlikely alive, ts=1 (ancient)
printf '## Summary\nok\n' | "$RELAY" save --dir "$DIR" --digest "after stale"
assert_contains "$(cat "$DIR/latest.md")" "after stale"

# (b) two concurrent saves both complete, serialized (no clobbered/partial latest.md)
setup_tmp; mkdir -p "$DIR"
( printf '## Summary\nA\n' | "$RELAY" save --dir "$DIR" --digest "A" ) &
( printf '## Summary\nB\n' | "$RELAY" save --dir "$DIR" --digest "B" ) &
wait
# both sessions landed in today's history; latest.md is one intact handoff
today="$(date +%F)"
assert_eq "$(grep -c '^session:' "$DIR/history/$today.md")" "2"
assert_contains "$(cat "$DIR/latest.md")" "session:"
pass "locking"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_05_lock.sh`
Expected: FAIL — the pre-seeded stale `.lock` dir is never broken (no locking yet); save proceeds but the test asserts the lock path. (If it passes accidentally, the concurrent sub-test will still expose missing serialization.)

- [ ] **Step 3: Implement locking**

Add near the other helpers:

```bash
_unlock() { [ -n "${DATA:-}" ] && rm -rf "$DATA/.lock" 2>/dev/null || true; }

_lock() {
  local lock="$DATA/.lock" waited=0 pid ts now
  mkdir -p "$DATA"
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -f "$lock/info" ]; then
      pid="$(sed -n '1p' "$lock/info" 2>/dev/null || true)"
      ts="$(sed -n '2p' "$lock/info" 2>/dev/null || printf 0)"
      now="$(date +%s)"
      if { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; } \
         || [ "$(( now - ${ts:-0} ))" -gt "$RELAY_LOCK_TIMEOUT" ]; then
        rm -rf "$lock"; continue
      fi
    fi
    waited=$(( waited + 1 ))
    [ "$waited" -gt "$RELAY_LOCK_TIMEOUT" ] && { echo "relay: lock wait timeout" >&2; return 1; }
    sleep 1
  done
  printf '%s\n%s\n' "$$" "$(date +%s)" > "$lock/info"
  trap _unlock EXIT
}
```

Wrap the critical section in `cmd_save` — acquire after authoring (body read), release at the end:

```bash
  body="$(cat)"
  date="$(date +%F)"
  mkdir -p "$DATA/history"
  _lock || return 1            # <-- acquire AFTER reading stdin (authoring is lock-free)
  # ... existing write/append/latest/index/prune ...
  _prune
  _unlock                      # <-- release
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_05_lock.sh`
Expected: `PASS: locking`

- [ ] **Step 5: Commit**

```bash
git add relay.sh tests/test_05_lock.sh
git commit -m "feat(relay): portable mkdir lock with stale-break + concurrency"
```

---

## Task 6: `relay load` — staleness, cap, format

**Files:**
- Modify: `relay.sh` (`cmd_load`, add `_json_escape`)
- Create: `tests/test_06_load.sh`

**Interfaces:**
- Consumes: `$DATA`, `to_epoch`, `$1` (format).
- Produces: `cmd_load FORMAT` prints, in `text` (default): a recency line (`Last saved: <date> (today)` / `⚠ … N days ago`), `latest.md` capped to ~800 words (with a truncation note), `index.md`, and an on-demand note. In `codex`: the same payload wrapped as `{"hookSpecificOutput":{"hookEventName":"SessionStart","systemMessage":"…"}}`. No `latest.md` → exit 0 silently. `_json_escape` escapes a stdin string for a JSON value.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_06_load.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

# empty state: silent, exit 0
out="$("$RELAY" load --dir "$DIR")"; assert_eq "$out" ""

# fresh save → "today"
printf '## Summary\nload me, see app.ts\n' | "$RELAY" save --dir "$DIR" --digest "d"
out="$("$RELAY" load --dir "$DIR")"
assert_contains "$out" "Last saved:"
assert_contains "$out" "(today)"
assert_contains "$out" "load me, see app.ts"
assert_contains "$out" "Session index"

# stale: backdate latest.md's frontmatter 9 days → ⚠ flag
old="$(date -v-9d +%F 2>/dev/null || date -d '9 days ago' +%F)"
tmp="$(mktemp)"; sed "s/^date: .*/date: $old/" "$DIR/latest.md" > "$tmp"; mv "$tmp" "$DIR/latest.md"
out="$("$RELAY" load --dir "$DIR")"
assert_contains "$out" "⚠"
assert_contains "$out" "days ago"

# codex format → JSON systemMessage
out="$("$RELAY" load --dir "$DIR" --format codex)"
assert_contains "$out" '"systemMessage"'
assert_contains "$out" '"hookEventName":"SessionStart"'
pass "load + staleness + codex format"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_06_load.sh`
Expected: FAIL (`cmd_load` is the Task-1 stub — prints nothing).

- [ ] **Step 3: Implement `cmd_load` + `_json_escape`**

Replace `cmd_load() { return 0; }` and add the escaper:

```bash
_json_escape() {
  awk 'BEGIN{ORS=""}
       { gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t");
         if (NR>1) printf "\\n"; printf "%s", $0 }'
}

cmd_load() {
  local format="${1:-text}" latest="$DATA/latest.md" idx="$DATA/index.md"
  [ -f "$latest" ] || return 0
  local sdate today se st days n out
  sdate="$(sed -n 's/^date:[[:space:]]*//p' "$latest" | head -n1)"
  today="$(date +%F)"; days=0
  if [ -n "$sdate" ]; then
    se="$(to_epoch "$sdate" 2>/dev/null || printf 0)"
    st="$(to_epoch "$today" 2>/dev/null || printf 0)"
    [ "${se:-0}" -gt 0 ] && [ "${st:-0}" -gt 0 ] && days=$(( (st - se) / 86400 ))
  fi
  if [ "$days" -le 0 ]; then
    out="Last saved: ${sdate:-unknown} (today)"$'\n\n'
  elif [ "$days" -gt "$RELAY_STALE_DAYS" ]; then
    out="⚠ Last saved: $sdate — $days days ago"$'\n\n'
  else
    out="Last saved: $sdate ($days day(s) ago)"$'\n\n'
  fi
  n="$(wc -w < "$latest" | tr -d ' ')"
  if [ "${n:-0}" -gt "$RELAY_WORD_CAP" ]; then
    out="$out$(awk -v cap="$RELAY_WORD_CAP" 'BEGIN{c=0}{c+=NF;print} c>=cap{print "\n…[truncated — open .session-log/latest.md for the full handoff]"; exit}' "$latest")"
  else
    out="$out$(cat "$latest")"
  fi
  [ -f "$idx" ] && out="$out"$'\n\n'"$(cat "$idx")"
  out="$out"$'\n\nOpen .session-log/history/<date>.md for the full detail of an earlier day.'
  if [ "$format" = "codex" ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","systemMessage":"%s"}}\n' \
      "$(printf '%s' "$out" | _json_escape)"
  else
    printf '%s\n' "$out"
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_06_load.sh`
Expected: `PASS: load + staleness + codex format`

- [ ] **Step 5: Run the whole core suite + commit**

Run: `for t in tests/test_0[1-6]_*.sh; do bash "$t"; done`
Expected: six `PASS:` lines.

```bash
git add relay.sh tests/test_06_load.sh
git commit -m "feat(relay): load with staleness flag, word cap, and codex JSON format"
```

---

## Task 7: Claude Code adapter

**Files:**
- Create: `adapters/claude-code/relay-session-start.sh`
- Create: `adapters/claude-code/commands/session-save.md`
- Create: `adapters/claude-code/CLAUDE.relay.md`
- Create: `tests/test_07_cc_adapter.sh`

**Interfaces:**
- Consumes: `relay.sh` at `$ROOT/.relay/relay.sh`; `$CLAUDE_PROJECT_DIR`.
- Produces: a SessionStart hook that prints `relay load` to stdout (CC injects stdout into context); a `/session-save` command (L1); a CLAUDE.md L2 block. No-op (exit 0) when `.relay/relay.sh` is absent.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_07_cc_adapter.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"; setup_tmp

# Simulate an installed target repo
mkdir -p "$TMP/.relay"; cp "$SRC/relay.sh" "$TMP/.relay/relay.sh"; chmod +x "$TMP/.relay/relay.sh"
cp "$SRC/adapters/claude-code/relay-session-start.sh" "$TMP/.relay/cc-start.sh"; chmod +x "$TMP/.relay/cc-start.sh"
( cd "$TMP" && printf '## Summary\nhello from cc\n' | .relay/relay.sh save --dir "$TMP/.session-log" --digest "d" )

# hook prints the handoff to stdout (plain text → CC context)
out="$(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" bash .relay/cc-start.sh)"
assert_contains "$out" "hello from cc"
assert_contains "$out" "Last saved:"

# command + L2 files exist and reference the save path
assert_contains "$(cat "$SRC/adapters/claude-code/commands/session-save.md")" "relay.sh"
assert_contains "$(cat "$SRC/adapters/claude-code/CLAUDE.relay.md")" "/session-save"
pass "cc adapter"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_07_cc_adapter.sh`
Expected: FAIL (adapter files don't exist).

- [ ] **Step 3: Create the SessionStart hook**

```bash
# adapters/claude-code/relay-session-start.sh
#!/usr/bin/env bash
# Claude Code SessionStart hook → prints the Relay handoff (stdout is injected into context).
set -euo pipefail
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -x "$ROOT/.relay/relay.sh" ] || exit 0
"$ROOT/.relay/relay.sh" load --dir "$ROOT/.session-log" 2>/dev/null || true
exit 0
```

- [ ] **Step 4: Create the `/session-save` command**

```markdown
<!-- adapters/claude-code/commands/session-save.md -->
---
description: Save a Relay handoff so the next session can pick up where you left off
---
Persist a Relay handoff for the next agent.

1. Author the six sections as concise markdown — `## Summary`, `## Changed`,
   `## Decisions`, `## Next`, `## Watch out`, `## Open questions` — naming real
   files/paths and dated facts. Compose a one-line digest.
2. Persist it. The script owns all file writes, rotation, and locking:

   ```bash
   printf '%s\n' '<<the six sections as markdown>>' \
     | "$CLAUDE_PROJECT_DIR/.relay/relay.sh" save \
         --dir "$CLAUDE_PROJECT_DIR/.session-log" \
         --digest '<<one-line digest>>'
   ```
3. Reply: "Handoff saved for the next session."
```

- [ ] **Step 5: Create the L2 wrap-up block**

```markdown
<!-- adapters/claude-code/CLAUDE.relay.md -->
## Relay — session handoff (L2)
When the user signals the session is wrapping up ("done for today", "let's
continue tomorrow", or a task completes and we're winding down), run
`/session-save` to persist a Relay handoff. If unsure the session is ending,
offer it in one line.
```

- [ ] **Step 6: Run test to verify it passes + commit**

Run: `chmod +x adapters/claude-code/relay-session-start.sh && bash tests/test_07_cc_adapter.sh`
Expected: `PASS: cc adapter`

```bash
git add adapters/claude-code tests/test_07_cc_adapter.sh
git commit -m "feat(relay): Claude Code adapter (SessionStart hook + /session-save + L2)"
```

---

## Task 8: Codex adapter

**Files:**
- Create: `adapters/codex/relay-session-start.sh`
- Create: `adapters/codex/skills/session-save/SKILL.md`
- Create: `adapters/codex/AGENTS.relay.md`
- Create: `adapters/codex/hooks.relay.toml`
- Create: `tests/test_08_codex_adapter.sh`

**Interfaces:**
- Consumes: `relay.sh` at `$ROOT/.relay/relay.sh`; `$CODEX_PROJECT_DIR`.
- Produces: a SessionStart hook that prints `relay load --format codex` (a `systemMessage` JSON object); a `$session-save` skill (L1); an AGENTS.md L2 block; a `config.toml` `[hooks]` snippet. The AGENTS.md block is the guaranteed load fallback if `systemMessage` injection proves UI-only.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_08_codex_adapter.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"; setup_tmp
mkdir -p "$TMP/.relay"; cp "$SRC/relay.sh" "$TMP/.relay/relay.sh"; chmod +x "$TMP/.relay/relay.sh"
cp "$SRC/adapters/codex/relay-session-start.sh" "$TMP/.relay/cx-start.sh"; chmod +x "$TMP/.relay/cx-start.sh"
( cd "$TMP" && printf '## Summary\nhello from codex\n' | .relay/relay.sh save --dir "$TMP/.session-log" --digest "d" )

out="$(cd "$TMP" && CODEX_PROJECT_DIR="$TMP" bash .relay/cx-start.sh)"
assert_contains "$out" '"systemMessage"'
assert_contains "$out" 'hello from codex'
# config + L2 + skill present
assert_contains "$(cat "$SRC/adapters/codex/hooks.relay.toml")" "SessionStart"
assert_contains "$(cat "$SRC/adapters/codex/skills/session-save/SKILL.md")" "relay.sh"
assert_contains "$(cat "$SRC/adapters/codex/AGENTS.relay.md")" "session-log"
pass "codex adapter"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_08_codex_adapter.sh`
Expected: FAIL (files absent).

- [ ] **Step 3: Create the Codex SessionStart hook**

```bash
# adapters/codex/relay-session-start.sh
#!/usr/bin/env bash
# Codex SessionStart hook → emits {systemMessage:<handoff>} JSON.
set -euo pipefail
ROOT="${CODEX_PROJECT_DIR:-$PWD}"
[ -x "$ROOT/.relay/relay.sh" ] || exit 0
"$ROOT/.relay/relay.sh" load --dir "$ROOT/.session-log" --format codex 2>/dev/null || true
exit 0
```

- [ ] **Step 4: Create the `$session-save` skill**

```markdown
<!-- adapters/codex/skills/session-save/SKILL.md -->
---
name: session-save
description: Save a Relay handoff for the next Codex session
---
Persist a Relay handoff for the next agent.

1. Author the six sections (`## Summary`, `## Changed`, `## Decisions`, `## Next`,
   `## Watch out`, `## Open questions`) and a one-line digest.
2. Run:

   ```bash
   printf '%s\n' '<<six sections>>' \
     | "${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" save \
         --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log" \
         --digest '<<one-line digest>>'
   ```
3. Reply: "Handoff saved for the next session."
```

- [ ] **Step 5: Create the config snippet and the AGENTS.md L2 / fallback block**

```toml
# adapters/codex/hooks.relay.toml — merge into .codex/config.toml
[[hooks.SessionStart]]
command = [".relay/adapters/codex/relay-session-start.sh"]
```

```markdown
<!-- adapters/codex/AGENTS.relay.md -->
## Relay — session handoff (L2 + load fallback)
At the START of a session, read `.session-log/latest.md` and `.session-log/index.md`
first — they are the last agent's handoff. When wrapping up ("done for today" /
"continue tomorrow"), run `$session-save` to persist a new handoff; offer it if unsure.
```

- [ ] **Step 6: Run test to verify it passes + commit**

Run: `chmod +x adapters/codex/relay-session-start.sh && bash tests/test_08_codex_adapter.sh`
Expected: `PASS: codex adapter`

```bash
git add adapters/codex tests/test_08_codex_adapter.sh
git commit -m "feat(relay): Codex adapter (SessionStart systemMessage + \$session-save + AGENTS fallback)"
```

- [ ] **Step 7: Manual smoke-test (record result, do not block)**

In a real Codex session in a test repo with the adapter installed, confirm the
`systemMessage` content actually appears in the model's context (ask the agent
"what did the last session do?" cold). If it does NOT, the AGENTS.relay.md block
is the guaranteed fallback — note the outcome in the PR description.

---

## Task 9: Installer

**Files:**
- Create: `install.sh`
- Create: `tests/test_09_install.sh`

**Interfaces:**
- Consumes: the source tree (run from repo root, or — once bundled — self-contained).
- Produces: `install.sh` that, run from a target repo root, detects `.claude/`/`.codex/`, lays down `.relay/` + `.session-log/`, wires each present adapter, appends the L2 block, and gitignores `.session-log/`. Idempotent (marker-guarded); precondition-gated (skip if no harness).

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_09_install.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"; TMP="$(mktemp -d)"

# target repo with Claude Code present
mkdir -p "$TMP/.claude"; ( cd "$TMP" && git init -q )
( cd "$TMP" && RELAY_SRC="$SRC" bash "$SRC/install.sh" --from "$SRC" )

assert_file "$TMP/.relay/relay.sh"
assert_file "$TMP/.claude/settings.json"
assert_contains "$(cat "$TMP/.gitignore")" ".session-log/"
assert_contains "$(cat "$TMP/.claude/settings.json")" "relay-session-start.sh"

# idempotent: second run adds no duplicate hook
before="$(grep -c "relay-session-start" "$TMP/.claude/settings.json")"
( cd "$TMP" && RELAY_SRC="$SRC" bash "$SRC/install.sh" --from "$SRC" )
after="$(grep -c "relay-session-start" "$TMP/.claude/settings.json")"
assert_eq "$before" "$after"
pass "install (cc) + idempotent + gitignore"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_09_install.sh`
Expected: FAIL (`install.sh` absent).

- [ ] **Step 3: Write `install.sh`**

```bash
#!/usr/bin/env bash
# install.sh — lay Relay into the current repo. (Bundled release embeds sources; --from uses a source tree.)
set -euo pipefail
MARK="# >>> relay >>>"
FROM=""; [ "${1:-}" = "--from" ] && FROM="$2"

copy_tool() {
  mkdir -p .relay
  if [ -n "$FROM" ]; then
    cp "$FROM/relay.sh" .relay/relay.sh
    cp -R "$FROM/adapters" .relay/adapters
  else
    emit_relay > .relay/relay.sh        # emit_* funcs exist only in the bundled install.sh (Task 10)
    emit_adapters
  fi
  chmod +x .relay/relay.sh
  find .relay/adapters -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
  mkdir -p .session-log/history
}

gitignore_data() {
  touch .gitignore
  grep -qF ".session-log/" .gitignore || printf '\n%s\n.session-log/\n' "$MARK" >> .gitignore
}

append_block() { # file, source-block
  local file="$1" src="$2"
  [ -f "$src" ] || return 0
  touch "$file"
  grep -qF "$MARK" "$file" 2>/dev/null && return 0
  { printf '\n%s\n' "$MARK"; cat "$src"; printf '%s\n' "# <<< relay <<<"; } >> "$file"
}

wire_cc() {
  mkdir -p .claude/commands
  [ -d .relay/adapters/claude-code/commands ] && cp .relay/adapters/claude-code/commands/*.md .claude/commands/ 2>/dev/null || true
  append_block CLAUDE.md .relay/adapters/claude-code/CLAUDE.relay.md
  local hook=".relay/adapters/claude-code/relay-session-start.sh"
  local sj=".claude/settings.json"
  local entry
  entry="$(printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s"}]}]}}' "$hook")"
  if [ ! -f "$sj" ]; then
    printf '%s\n' "$entry" > "$sj"; return 0
  fi
  grep -qF "$hook" "$sj" && return 0    # idempotent
  if command -v jq >/dev/null 2>&1; then
    jq --arg c "$hook" '.hooks.SessionStart += [{"hooks":[{"type":"command","command":$c}]}]' "$sj" > "$sj.tmp" && mv "$sj.tmp" "$sj"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$sj" "$hook" <<'PY'
import json,sys
p,hook=sys.argv[1],sys.argv[2]
d=json.load(open(p)); d.setdefault("hooks",{}).setdefault("SessionStart",[]).append({"hooks":[{"type":"command","command":hook}]})
json.dump(d,open(p,"w"),indent=2)
PY
  else
    echo "relay: cannot auto-merge $sj — add this SessionStart hook manually:" >&2
    echo "  $entry" >&2
  fi
}

wire_codex() {
  mkdir -p .codex/skills
  [ -d .relay/adapters/codex/skills ] && cp -R .relay/adapters/codex/skills/* .codex/skills/ 2>/dev/null || true
  append_block AGENTS.md .relay/adapters/codex/AGENTS.relay.md
  local cfg=".codex/config.toml"
  touch "$cfg"
  grep -qF "relay-session-start.sh" "$cfg" 2>/dev/null || cat .relay/adapters/codex/hooks.relay.toml >> "$cfg"
}

main() {
  local did=0
  [ -d .claude ] && { copy_tool; wire_cc; did=1; }
  [ -d .codex ]  && { copy_tool; wire_codex; did=1; }
  if [ "$did" = 0 ]; then
    echo "relay: no .claude/ or .codex/ detected — nothing to wire. Re-run inside a Claude Code or Codex repo." >&2
    exit 0
  fi
  gitignore_data
  echo "relay: installed. Handoffs will accumulate in .session-log/ (gitignored)."
}
main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_09_install.sh`
Expected: `PASS: install (cc) + idempotent + gitignore`

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/test_09_install.sh
git commit -m "feat(relay): idempotent installer (detect, lay down, wire, gitignore)"
```

---

## Task 10: Bundler → single embedded `install.sh`, README, full suite

**Files:**
- Create: `bundle.sh`
- Create: `README.md`
- Create: `tests/test_10_bundle.sh`

**Interfaces:**
- Consumes: `relay.sh`, `adapters/`, `install.sh`.
- Produces: `bundle.sh` writes `dist/install.sh` — a self-contained installer with `relay.sh` and every adapter file embedded as heredocs, plus `emit_relay`/`emit_adapters` so the no-`--from` install path works offline.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_10_bundle.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"
( cd "$SRC" && bash bundle.sh )
assert_file "$SRC/dist/install.sh"

# the bundled installer works with NO source tree (offline), in a fresh CC repo
TMP="$(mktemp -d)"; mkdir -p "$TMP/.claude"; ( cd "$TMP" && git init -q )
( cd "$TMP" && bash "$SRC/dist/install.sh" )
assert_file "$TMP/.relay/relay.sh"
( cd "$TMP" && printf '## Summary\nbundled ok\n' | .relay/relay.sh save --dir "$TMP/.session-log" --digest "d" )
assert_contains "$(cd "$TMP" && .relay/relay.sh load --dir "$TMP/.session-log")" "bundled ok"
pass "bundle → offline install works"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_10_bundle.sh`
Expected: FAIL (`bundle.sh` absent).

- [ ] **Step 3: Write `bundle.sh`**

```bash
#!/usr/bin/env bash
# bundle.sh — concatenate sources into dist/install.sh (embedded heredocs).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dist
OUT="dist/install.sh"

emit_heredoc() { # varfunc, path
  local fn="$1" path="$2"
  printf '%s() { cat <<'"'"'RELAY_EOF'"'"'\n' "$fn"
  cat "$path"
  printf '\nRELAY_EOF\n}\n\n'
}

{
  # 1. emitter functions that reproduce each source file
  emit_heredoc emit_relay relay.sh
  printf 'emit_adapters() {\n'
  while IFS= read -r f; do
    rel="${f#./}"
    printf '  mkdir -p ".relay/%s"\n' "$(dirname "$rel")"
    printf '  emit__%s > ".relay/%s"\n' "$(echo "$rel" | tr './-' '___')" "$rel"
  done < <(cd . && find adapters -type f | sort)
  printf '}\n\n'
  while IFS= read -r f; do
    rel="${f#./}"
    emit_heredoc "emit__$(echo "$rel" | tr './-' '___')" "$rel"
  done < <(cd . && find adapters -type f | sort)
  # 2. the installer body (skips its own `emit_*`-only `--from` branch when bundled)
  cat install.sh
} > "$OUT"
chmod +x "$OUT"
echo "wrote $OUT"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_10_bundle.sh`
Expected: `PASS: bundle → offline install works`

If FAIL because `emit_adapters` paths don't match: confirm the `tr './-' '___'` mangling in `bundle.sh` matches between the emitter-definition loop and the `emit_adapters` call loop (same expression in both).

- [ ] **Step 5: Write the README**

```markdown
<!-- README.md -->
# Relay — portable session handoff

Agents hand off to each other day-to-day across a rolling 10-day window. Local,
gitignored, cross-harness (Claude Code + Codex).

## Install (in any repo)

```bash
curl -fsSL https://<host>/relay/install.sh | bash
# or: download install.sh, read it, then `bash install.sh`
```

It lays down `.relay/` (the tool, committed), wires the SessionStart hook + a save
command for whichever harness it finds, and gitignores `.session-log/` (your
handoffs — local only).

## Use

- Auto-loads the last handoff at session start.
- Run `/session-save` (Claude Code) or `$session-save` (Codex) to write one — or
  the agent offers when you wrap up.
```

- [ ] **Step 6: Run the FULL suite + commit**

Run: `for t in tests/test_*.sh; do bash "$t" || exit 1; done; echo ALL GREEN`
Expected: ten `PASS:` lines then `ALL GREEN`.

```bash
git add bundle.sh README.md dist/install.sh tests/test_10_bundle.sh
git commit -m "feat(relay): bundler → single embedded install.sh + README + green suite"
```

---

## Self-Review

**1. Spec coverage**

| Spec section | Implemented by |
|---|---|
| §4 deterministic helper; agent authors prose | Tasks 2–6 (`relay.sh`), §Global Constraints |
| §5 layout, frontmatter, one-line-per-day index | Tasks 2, 3 (`_index_update`) |
| §6 save triggers L1/L2 + behavior | Tasks 7, 8 (command/skill + L2 blocks); Tasks 2–5 (behavior) |
| §7 load: staleness, ~800-word cap, on-demand note | Task 6 |
| §8 window = 10 most-recent dated files | Task 4 |
| §9 symmetric adapters (CC stdout / Codex systemMessage) | Tasks 7, 8 + `--format` (Task 6) |
| §10 wait-your-turn lock (portable) | Task 5 |
| §11 `.session-log/` gitignored, `.relay/` committed | Task 9 (`gitignore_data`, `copy_tool`) |
| §12 transfer package = single embedded `install.sh` | Tasks 9, 10 |
| §14 lifecycle/concurrency/orientation/staleness/idempotency/trigger tests | Tasks 1–10 test files |

No spec section is unimplemented. (L3 autosave, PreCompact, git-diff recovery, `relay digest`, generic adapter, plugin/npx channels are §17 v2 — intentionally absent.)

**2. Placeholder scan** — no "TBD/TODO/handle edge cases/similar to Task N". The only `<<…>>` tokens are inside the command/skill *templates*, where they are deliberate fill-ins for the agent at runtime, not plan placeholders.

**3. Type/name consistency** — `relay.sh` subcommands (`load`/`save`), flags (`--dir`/`--format`/`--digest`), and functions (`to_epoch`, `_lock`, `_unlock`, `_index_update`, `_prune`, `_json_escape`, `cmd_load`, `cmd_save`) are used identically across tasks. Hook filenames (`relay-session-start.sh`) match between the adapter tasks (7, 8), the installer (Task 9 `wire_cc`/`wire_codex`), and the bundler (Task 10). Data paths (`.session-log/`, `.relay/`) are consistent throughout.

---

## Execution notes

- **Branch first.** This work should land on a dedicated branch (e.g. `feature/relay-session-handoff`), not the current `feature/h2-ui-mockups-260606`. Create it (or an isolated worktree via `superpowers:using-git-worktrees`) before Task 1.
- **The Relay source repo is standalone.** These files live in their own repo/dir, not under the Forge workspace tree. Decide the source location before Task 1 (a sibling dir or a new `github.com/<you>/relay`).
- **Run order:** tasks are strictly sequential (each builds on the prior `relay.sh` state). Run the full suite (Task 10, Step 6) as the final gate.
