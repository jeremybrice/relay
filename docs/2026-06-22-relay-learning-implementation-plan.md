# Relay Learning Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a durable, local-only learning + memory layer to Relay — facts and lessons captured at save time, reinforced on recurrence, graduated into the harness instruction file — entirely inside the existing deterministic `relay.sh` helper, with no daemon and no new dependencies.

**Architecture:** Extend `relay.sh` with a `knowledge` command group (`add`/`resolve`/`graduate`/`ungraduate`/`supersede`/`prune`/`why`/`list`/`export`) that does every file write under the existing `mkdir` lock. The agent authors only an `id` slug + prose; the helper owns counters, conflict detection, the idempotent instruction-block edit, and a derived `knowledge/index.md`. **Load reads the entry files directly as ground truth** (the persisted index is a convenience, never load-bearing), so index drift can never reach the agent. Two thin adapter touches add a `/relay-learn` command and one capture instruction per harness.

**Tech Stack:** POSIX-ish bash targeting **bash 3.2.57** (stock macOS), zero runtime dependencies, BSD/GNU-portable `date`. Tests are standalone scripts in `tests/` using the existing `helper.sh` assert library. The bundler (`bundle.sh`) auto-embeds `relay.sh` and every file under `adapters/`, so no bundler edits are needed.

## Global Constraints

Copied verbatim from `2026-06-22-relay-learning-design.md`. Every task's requirements implicitly include this section.

- **bash 3.2 only.** No `flock`, no `mapfile`/`readarray`, no associative arrays in shipped code (awk may use them internally). Empty-array expansion under `set -euo pipefail` must use `${arr[@]+"${arr[@]}"}`.
- **Date math is BSD-form first:** reuse the existing `to_epoch()` (`date -d … 2>/dev/null || date -j -f "%Y-%m-%d" …`). Never assume GNU `date -d`.
- **Zero dependencies.** Only coreutils available on stock macOS: `sed`, `awk`, `grep`, `sort`, `tr`, `cut`, `mktemp`, `printf`, `date`. No `jq`/`yq`/`python` in `relay.sh` (the installer may still use them for JSON merge — unchanged).
- **The helper owns every byte write; the agent authors only `id` + prose.** Mechanics are deterministic; the create/confirm/conflict *outcome* is agent-determined and made visible (`--near`) and reversible (conflict markers, tombstones).
- **All knowledge data is local-only and gitignored** under `.session-log/knowledge/` (the existing `.session-log/` gitignore entry already covers it). The single local→committed leak is graduation, which writes to `CLAUDE.md`/`AGENTS.md`; it is gated.
- **Mutations hold the existing lock** (`_lock`/`_unlock` on `$DATA/.lock`). **Load never locks** and never blocks.
- **Naming:** subcommand group is `knowledge`; data dir `knowledge/`; instruction region markers `<!-- relay:learned -->` … `<!-- /relay:learned -->` with per-id inner markers `<!-- relay:learned:<id> -->` … `<!-- /relay:learned:<id> -->`.
- **Graduation gate is distinct sessions**, env-overridable: `RELAY_GRADUATE_AT` (default 3). Other tunables: `RELAY_FACTS_CAP` (400), `RELAY_LESSONS_CAP` (400), `RELAY_FACT_STALE_DAYS` (90). Test override of the instruction file target: `RELAY_INSTRUCTION_FILE`.

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `relay.sh` | core helper — gains the entire `knowledge` group, the load-knowledge block, and shared frontmatter helpers | **Modify** |
| `tests/test_11_knowledge_lesson.sh` | lesson add / reinforce / sessions gate | Create |
| `tests/test_12_knowledge_fact.sh` | fact add / confirm / conflict | Create |
| `tests/test_13_knowledge_near.sh` | `--near` dedup prompt | Create |
| `tests/test_14_knowledge_resolve.sh` | conflict resolution | Create |
| `tests/test_15_knowledge_list.sh` | list + derived-index rebuild + flags | Create |
| `tests/test_16_knowledge_graduate.sh` | graduation block (4-case) + move + idempotency | Create |
| `tests/test_17_knowledge_ungraduate.sh` | ungraduate + supersede | Create |
| `tests/test_18_knowledge_prune.sh` | gated staleness prune | Create |
| `tests/test_19_knowledge_load.sh` | load injection, non-silent caps, ttl/conflict nudges, codex JSON | Create |
| `tests/test_20_knowledge_why_export.sh` | `why` provenance + `export` | Create |
| `tests/test_21_adapter_bundle.sh` | new `/relay-learn` adapter wired; bundle still offline-installs | Create |
| `adapters/claude-code/commands/relay-learn.md` | CC `/relay-learn` command | Create |
| `adapters/codex/skills/relay-learn/SKILL.md` | Codex `$relay-learn` skill | Create |
| `adapters/claude-code/CLAUDE.relay.md` | + capture instruction | **Modify** |
| `adapters/codex/AGENTS.relay.md` | + capture instruction | **Modify** |
| `adapters/claude-code/commands/session-save.md` | + capture step | **Modify** |
| `adapters/codex/skills/session-save/SKILL.md` | + capture step | **Modify** |

A test runner one-liner used throughout: `for t in tests/test_*.sh; do bash "$t" || exit 1; done`.

---

## Task 1: Lesson capture — `knowledge add --lesson` + the shared helper foundation

This task introduces the `knowledge` dispatch and the shared frontmatter helpers that every later task consumes, delivered through the first user-visible subcommand.

**Files:**
- Modify: `relay.sh` (add constants near the existing config block; add functions before `main`; add a `knowledge` branch in `main`)
- Test: `tests/test_11_knowledge_lesson.sh`

**Interfaces:**
- Consumes: existing `_lock`/`_unlock` (lock on `$DATA/.lock`), `to_epoch`, `DATA` (set in `main`).
- Produces (used by all later tasks):
  - `_slugify <str>` → normalized slug on stdout (lowercase, non-alnum→`-`, squeezed, trimmed, ≤48 chars)
  - `_fm <file> <key>` → value of a frontmatter scalar (`key: value`) on stdout, empty if absent
  - `_fm_set <file> <key> <value>` → rewrite that scalar in the frontmatter in place (whole-file atomic rewrite)
  - `_body <file>` → everything after the second `---` line on stdout
  - `_set_body <file> <body>` → replace the body (keep frontmatter) in place
  - `_provenance` → `history/<today>.md[#session-N]` string
  - `_days_since <YYYY-MM-DD>` → integer days since that date (999999 if empty/unparseable)
  - `_write_lesson <file> <id> <seen> <sessions> <first> <last> <source> <body>`
  - `_kindex` → rebuild `$DATA/knowledge/index.md` from entry files (depth-1 globs, tombstone subdirs excluded)
  - `cmd_knowledge <args…>` → the dispatcher (strips a `--dir` appearing anywhere, then routes the subcommand)
  - `k_add <args…>` → handles `--lesson`/`--fact`, `--near`, `--id`, body

- [ ] **Step 1: Write the failing test**

Create `tests/test_11_knowledge_lesson.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
today="$(date +%F)"
KD="$DIR/knowledge/lessons"

# create a lesson
out="$("$RELAY" knowledge add --lesson --id schema-types-first "Regenerate types before call-sites." --dir "$DIR")"
assert_contains "$out" "added lesson: schema-types-first"
assert_file "$KD/schema-types-first.md"
assert_contains "$(cat "$KD/schema-types-first.md")" "seen: 1"
assert_contains "$(cat "$KD/schema-types-first.md")" "sessions: 1"
assert_contains "$(cat "$KD/schema-types-first.md")" "Regenerate types before call-sites."
assert_contains "$(cat "$KD/schema-types-first.md")" "source: history/$today.md"

# reinforce SAME day → seen bumps, sessions unchanged
out="$("$RELAY" knowledge add --lesson --id schema-types-first "Regen types first, always." --dir "$DIR")"
assert_contains "$out" "reinforced lesson: schema-types-first"
assert_contains "$(cat "$KD/schema-types-first.md")" "seen: 2"
assert_contains "$(cat "$KD/schema-types-first.md")" "sessions: 1"
assert_contains "$(cat "$KD/schema-types-first.md")" "Regen types first, always."

# slug normalization: messy --id is normalized
"$RELAY" knowledge add --lesson --id "Use Tabs, Not Spaces!" "tabs here" --dir "$DIR" >/dev/null
assert_file "$KD/use-tabs-not-spaces.md"

# derived index lists the active lessons
assert_file "$DIR/knowledge/index.md"
assert_contains "$(cat "$DIR/knowledge/index.md")" "lesson · schema-types-first · seen:2 · sessions:1"

# distinct-session gate (R6): reinforce on a LATER day → sessions increments (not just seen)
old="$(date -v-2d +%F 2>/dev/null || date -d '2 days ago' +%F)"
tmp="$(mktemp)"; sed "s/^last_seen: .*/last_seen: $old/" "$KD/schema-types-first.md" > "$tmp"; mv "$tmp" "$KD/schema-types-first.md"
"$RELAY" knowledge add --lesson --id schema-types-first "Regen types, day two." --dir "$DIR" >/dev/null
assert_contains "$(cat "$KD/schema-types-first.md")" "sessions: 2"

# a third distinct day reaches the gate → the graduation-ready prompt appears
tmp="$(mktemp)"; sed "s/^last_seen: .*/last_seen: $old/" "$KD/schema-types-first.md" > "$tmp"; mv "$tmp" "$KD/schema-types-first.md"
out="$("$RELAY" knowledge add --lesson --id schema-types-first "Regen types, day three." --dir "$DIR")"
assert_contains "$(cat "$KD/schema-types-first.md")" "sessions: 3"
assert_contains "$out" "graduation-ready"
pass "knowledge add --lesson: create, same-day reinforce, distinct-session gate, slug, index"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_11_knowledge_lesson.sh`
Expected: FAIL (knowledge subcommand unknown / file missing).

- [ ] **Step 3: Add constants and helpers to `relay.sh`**

After the existing config block (the `RELAY_LOCK_TIMEOUT=30` line), add:

```bash
RELAY_GRADUATE_AT="${RELAY_GRADUATE_AT:-3}"
RELAY_FACTS_CAP="${RELAY_FACTS_CAP:-400}"
RELAY_LESSONS_CAP="${RELAY_LESSONS_CAP:-400}"
RELAY_FACT_STALE_DAYS="${RELAY_FACT_STALE_DAYS:-90}"
RELAY_GRADUATED_SOFT="${RELAY_GRADUATED_SOFT:-8}"
```

Before `main()`, add the shared helpers:

```bash
_slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' \
    | tr -s '-' | sed -e 's/^-//' -e 's/-$//' | cut -c1-48
}

_fm() { sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -n1; }

_fm_set() { # file key value  (whole-file atomic rewrite; only inside frontmatter)
  local tmp; tmp="$(mktemp)"
  awk -v k="$2" -v v="$3" 'BEGIN{d=0}
    /^---$/{d++}
    { if(d==1 && index($0,k": ")==1){ print k": "v; next } print }' "$1" > "$tmp"
  mv "$tmp" "$1"
}

_body() { awk 'BEGIN{d=0} /^---$/{d++; next} d>=2{print}' "$1"; }

_set_body() { # file body
  local tmp; tmp="$(mktemp)"
  awk 'BEGIN{d=0} {print} /^---$/{d++; if(d==2) exit}' "$1" > "$tmp"
  printf '%s\n' "$2" >> "$tmp"
  mv "$tmp" "$1"
}

_provenance() {
  local src sess
  src="history/$(date +%F).md"
  if [ -f "$DATA/latest.md" ]; then
    sess="$(sed -n 's/^session:[[:space:]]*//p' "$DATA/latest.md" | head -n1)"
    [ -n "$sess" ] && src="$src#session-$sess"
  fi
  printf '%s' "$src"
}

_days_since() {
  local d="$1" e n
  [ -n "$d" ] || { printf '999999'; return; }
  e="$(to_epoch "$d" 2>/dev/null || printf 0)"; n="$(date +%s)"
  if [ "${e:-0}" -gt 0 ]; then printf '%s' $(( (n - e) / 86400 )); else printf '999999'; fi
}

_write_lesson() { # file id seen sessions first last source body
  printf -- '---\nid: %s\nkind: lesson\nseen: %s\nsessions: %s\nfirst_seen: %s\nlast_seen: %s\nsource: %s\nstatus: active\ngraduated_to: null\n---\n%s\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" > "$1"
}

_kindex() { # derived convenience cache; never load-bearing
  local kd="$DATA/knowledge" idx tmp f id
  mkdir -p "$kd"; idx="$kd/index.md"; tmp="$(mktemp)"
  printf '# Knowledge index — derived from entry files; do not edit\n' > "$tmp"
  for f in "$kd"/facts/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"
    printf 'fact · %s · confirmed:%s · last:%s · ttl:%s · conflict:%s\n' \
      "$id" "$(_fm "$f" confirmed)" "$(_fm "$f" last_confirmed)" "$(_fm "$f" ttl)" \
      "$([ -f "$kd/facts/$id.conflict" ] && printf 1 || printf 0)" >> "$tmp"
  done
  for f in "$kd"/lessons/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"
    printf 'lesson · %s · seen:%s · sessions:%s · last:%s · status:active\n' \
      "$id" "$(_fm "$f" seen)" "$(_fm "$f" sessions)" "$(_fm "$f" last_seen)" >> "$tmp"
  done
  mv "$tmp" "$idx"
}

cmd_knowledge() {
  local kept=() ; while [ $# -gt 0 ]; do
    case "$1" in
      --dir) DATA="$2"; shift 2;;
      *) kept+=("$1"); shift;;
    esac
  done
  set -- ${kept[@]+"${kept[@]}"}
  local sub="${1:-}"; [ $# -gt 0 ] && shift || true
  case "$sub" in
    add)        k_add "$@";;
    *) echo "relay: unknown knowledge subcommand: ${sub:-(none)}" >&2; return 2;;
  esac
}

k_add() {
  local kind="" near=0 id="" ttl="none" rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --fact)   kind="fact";   shift;;
      --lesson) kind="lesson"; shift;;
      --near)   near=1;        shift;;
      --id)     id="$2";       shift 2;;
      --ttl)    ttl="$2";      shift 2;;
      *)        rest+=("$1");  shift;;
    esac
  done
  set -- ${rest[@]+"${rest[@]}"}
  local body="${1:-}"
  [ -n "$kind" ] || { echo "relay: knowledge add needs --fact or --lesson" >&2; return 2; }
  [ -n "$id" ] || { echo "relay: knowledge add needs --id <slug>" >&2; return 2; }
  id="$(_slugify "$id")"
  _lock || return 1
  mkdir -p "$DATA/knowledge/facts" "$DATA/knowledge/lessons"
  if [ "$kind" = lesson ]; then _k_add_lesson "$id" "$body"; fi
  _kindex
  _unlock
}

_k_add_lesson() {
  local id="$1" body="$2" f="$DATA/knowledge/lessons/$1.md" today
  today="$(date +%F)"
  if [ -f "$f" ]; then
    local seen sess last
    seen="$(_fm "$f" seen)"; sess="$(_fm "$f" sessions)"; last="$(_fm "$f" last_seen)"
    seen=$(( ${seen:-1} + 1 ))
    [ "$last" != "$today" ] && sess=$(( ${sess:-1} + 1 ))
    _fm_set "$f" seen "$seen"; _fm_set "$f" sessions "$sess"; _fm_set "$f" last_seen "$today"
    _set_body "$f" "$body"
    echo "reinforced lesson: $id (seen:$seen sessions:$sess)"
    if [ "$sess" -ge "$RELAY_GRADUATE_AT" ]; then
      echo "  → graduation-ready (sessions:$sess ≥ $RELAY_GRADUATE_AT): propose 'relay knowledge graduate $id'"
    fi
  else
    _write_lesson "$f" "$id" 1 1 "$today" "$today" "$(_provenance)" "$body"
    echo "added lesson: $id (seen:1 sessions:1)"
  fi
  return 0   # never let a false test/[-ge] make this function exit non-zero under set -e
}
```

- [ ] **Step 4: Wire the `knowledge` branch into `main`**

In `main()`, immediately after the line `DATA="${RELAY_DIR:-$PWD/.session-log}"`, add a short-circuit so the generic `--dir/--format/--digest` loop never sees `knowledge` args:

```bash
  if [ "$cmd" = knowledge ]; then cmd_knowledge "$@"; return $?; fi
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_11_knowledge_lesson.sh`
Expected: `PASS: knowledge add --lesson: create, same-day reinforce, slug, index`

- [ ] **Step 6: Run the full suite (no regressions)**

Run: `for t in tests/test_*.sh; do bash "$t" || exit 1; done`
Expected: every existing test still prints `PASS`, plus the new one.

- [ ] **Step 7: Commit**

```bash
git add relay.sh tests/test_11_knowledge_lesson.sh
git commit -m "feat(relay): knowledge add --lesson + shared frontmatter/index helpers"
```

---

## Task 2: Fact capture — `knowledge add --fact` with confirm-vs-conflict

**Files:**
- Modify: `relay.sh` (route `--fact` in `k_add`; add fact helpers)
- Test: `tests/test_12_knowledge_fact.sh`

**Interfaces:**
- Consumes: `_slugify`, `_fm`, `_fm_set`, `_body`, `_provenance`, `_kindex`, `_lock`/`_unlock` (Task 1).
- Produces:
  - `_write_fact <file> <id> <confirmed> <first> <last> <ttl> <source> <body>`
  - `_dice <bodyA> <bodyB>` → integer 0–100 (Dice token-overlap percent)
  - `_similar <bodyA> <bodyB>` → exit 0 if `_dice ≥ 50`
  - `_k_add_fact <id> <body>` → create | confirm | raise conflict (writes `facts/<id>.conflict` on divergence)

- [ ] **Step 1: Write the failing test**

Create `tests/test_12_knowledge_fact.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
F="$DIR/knowledge/facts"

# create a fact
out="$("$RELAY" knowledge add --fact --id deploy-release-script "Deploys ship via scripts/release.sh, never npm publish." --dir "$DIR")"
assert_contains "$out" "added fact: deploy-release-script"
assert_file "$F/deploy-release-script.md"
assert_contains "$(cat "$F/deploy-release-script.md")" "confirmed: 1"
assert_contains "$(cat "$F/deploy-release-script.md")" "ttl: none"

# re-assert a SIMILAR body → confirm (bump, no overwrite of meaning, no dup file)
out="$("$RELAY" knowledge add --fact --id deploy-release-script "Deploys ship through scripts/release.sh and never npm publish directly." --dir "$DIR")"
assert_contains "$out" "confirmed: deploy-release-script"
assert_contains "$(cat "$F/deploy-release-script.md")" "confirmed: 2"

# re-assert a DIVERGENT body on the same id → conflict, NOT overwrite
out="$("$RELAY" knowledge add --fact --id deploy-release-script "Auth lives in src/auth/session.ts and uses JWT." --dir "$DIR")"
assert_contains "$out" "conflict raised for fact: deploy-release-script"
assert_file "$F/deploy-release-script.conflict"
# original body is intact (not overwritten)
assert_contains "$(cat "$F/deploy-release-script.md")" "scripts/release.sh"
assert_contains "$(cat "$F/deploy-release-script.conflict")" "Auth lives in src/auth/session.ts"
# index marks the conflict
assert_contains "$(cat "$DIR/knowledge/index.md")" "deploy-release-script · confirmed:2 · last:"
assert_contains "$(cat "$DIR/knowledge/index.md")" "conflict:1"

# --ttl persists a real freshness window (so the TTL read-side is not dead code)
"$RELAY" knowledge add --fact --id current-sprint --ttl 14 "Sprint is the checkout rewrite." --dir "$DIR" >/dev/null
assert_contains "$(cat "$DIR/knowledge/facts/current-sprint.md")" "ttl: 14"
pass "knowledge add --fact: create, confirm, conflict-not-overwrite, ttl"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_12_knowledge_fact.sh`
Expected: FAIL (fact not created — `--fact` not yet routed).

- [ ] **Step 3: Add fact helpers and route `--fact` in `relay.sh`**

In `k_add`, change the dispatch line to also handle facts:

```bash
  if [ "$kind" = lesson ]; then _k_add_lesson "$id" "$body"; else _k_add_fact "$id" "$body" "$ttl"; fi
```

Add the fact helpers before `cmd_knowledge`:

```bash
_write_fact() { # file id confirmed first last ttl source body
  printf -- '---\nid: %s\nkind: fact\nconfirmed: %s\nfirst_seen: %s\nlast_confirmed: %s\nttl: %s\nsource: %s\nstatus: active\n---\n%s\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" > "$1"
}

_dice() { # bodyA bodyB -> integer 0..100 (Dice coefficient over unique lowercase tokens)
  awk -v A="$1" -v B="$2" 'BEGIN{
    na=split(tolower(A),aa,/[^a-z0-9]+/); nb=split(tolower(B),bb,/[^a-z0-9]+/);
    for(i=1;i<=na;i++) if(aa[i]!="") sa[aa[i]]=1;
    for(i=1;i<=nb;i++) if(bb[i]!="") sb[bb[i]]=1;
    ca=0; for(k in sa) ca++; cb=0; for(k in sb) cb++;
    inter=0; for(k in sa) if(k in sb) inter++;
    if(ca+cb==0){print 0; exit}
    printf "%d", (inter*200)/(ca+cb);
  }'
}

_similar() { [ "$(_dice "$1" "$2")" -ge 50 ]; }

_k_add_fact() {
  local id="$1" body="$2" ttl="${3:-none}" f="$DATA/knowledge/facts/$1.md" today
  today="$(date +%F)"
  if [ -f "$f" ]; then
    if _similar "$(_body "$f")" "$body"; then
      local c; c="$(_fm "$f" confirmed)"; c=$(( ${c:-1} + 1 ))
      _fm_set "$f" confirmed "$c"; _fm_set "$f" last_confirmed "$today"
      [ "$ttl" != none ] && _fm_set "$f" ttl "$ttl"    # refresh freshness window if the agent re-set it
      echo "confirmed: $id (confirmed:$c)"
    else
      printf '%s\n' "$body" > "$DATA/knowledge/facts/$id.conflict"
      echo "⚠ conflict raised for fact: $id — run: relay knowledge resolve $id"
    fi
  else
    _write_fact "$f" "$id" 1 "$today" "$today" "$ttl" "$(_provenance)" "$body"
    echo "added fact: $id"
  fi
  return 0
}
```

> **`--ttl` note (closes the inert-TTL gap):** `ttl` defaults to `none` (near-permanent). The agent sets a real window for time-bound facts, e.g. `relay knowledge add --fact --id current-sprint --ttl 14 "Sprint is the checkout rewrite."` — at load and in `prune`, a fact past `last_confirmed + ttl` days is flagged (Tasks 8–9). Without a real `ttl`, those branches are dead code, so the `--ttl` flag is required, not optional.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_12_knowledge_fact.sh`
Expected: `PASS: knowledge add --fact: create, confirm, conflict-not-overwrite`

- [ ] **Step 5: Commit**

```bash
git add relay.sh tests/test_12_knowledge_fact.sh
git commit -m "feat(relay): knowledge add --fact with confirm-vs-conflict (no silent overwrite)"
```

---

## Task 3: `--near` dedup prompt

**Files:**
- Modify: `relay.sh` (handle `--near` in `k_add` before requiring `--id`)
- Test: `tests/test_13_knowledge_near.sh`

**Interfaces:**
- Consumes: `_fm` (Task 1).
- Produces: `_k_near <kind> <body>` → prints up to 3 candidate ids by token overlap; writes nothing.

- [ ] **Step 1: Write the failing test**

Create `tests/test_13_knowledge_near.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

"$RELAY" knowledge add --fact --id deploy-release-script "Deploys ship via scripts/release.sh." --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact --id test-db-resets "The integration test database resets every run." --dir "$DIR" >/dev/null

# --near surfaces the closest existing id, writes nothing new
before="$(ls "$DIR/knowledge/facts" | wc -l | tr -d ' ')"
out="$("$RELAY" knowledge add --fact --near "How do we ship a release / deploy?" --dir "$DIR")"
assert_contains "$out" "deploy-release-script"
after="$(ls "$DIR/knowledge/facts" | wc -l | tr -d ' ')"
assert_eq "$after" "$before"

# --near on an empty store says so, writes nothing
setup_tmp
out="$("$RELAY" knowledge add --fact --near "anything" --dir "$DIR")"
assert_contains "$out" "no"
pass "knowledge add --near: candidate ids, no write"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_13_knowledge_near.sh`
Expected: FAIL (`--near` currently falls through to the `--id` requirement and errors).

- [ ] **Step 3: Handle `--near` in `k_add` and add `_k_near`**

In `k_add`, after computing `kind` but before the `--id` requirement, insert the near short-circuit. Replace the block from `[ -n "$kind" ] || …` down through `id="$(_slugify "$id")"` with:

```bash
  [ -n "$kind" ] || { echo "relay: knowledge add needs --fact or --lesson" >&2; return 2; }
  if [ "$near" = 1 ]; then _k_near "$kind" "$body"; return 0; fi
  [ -n "$id" ] || { echo "relay: knowledge add needs --id <slug>" >&2; return 2; }
  id="$(_slugify "$id")"
```

Add `_k_near` before `cmd_knowledge`:

```bash
_k_near() { # kind body
  local dir="$DATA/knowledge/${1}s" body="$2" f id sc w words hits=""
  [ -d "$dir" ] || { echo "(no existing ${1}s yet — safe to create a new id)"; return 0; }
  words="$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '\n' \
            | awk 'length>=4' | sort -u)"
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"; sc=0
    for w in $words; do grep -qiF -- "$w" "$f" && sc=$(( sc + 1 )); done
    [ "$sc" -gt 0 ] && hits="$hits$sc $id
"
  done
  if [ -n "$hits" ]; then
    echo "Closest existing ${1} ids (reuse one as --id if it matches):"
    printf '%s' "$hits" | sort -rn | head -n3 | awk '{printf "  - %s (overlap %s)\n",$2,$1}'
  else
    echo "(no near matches — safe to create a new id)"
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_13_knowledge_near.sh`
Expected: `PASS: knowledge add --near: candidate ids, no write`

- [ ] **Step 5: Commit**

```bash
git add relay.sh tests/test_13_knowledge_near.sh
git commit -m "feat(relay): knowledge add --near dedup prompt"
```

---

## Task 4: `knowledge resolve` — settle a fact conflict

**Files:**
- Modify: `relay.sh` (dispatch `resolve`; add `k_resolve`)
- Test: `tests/test_14_knowledge_resolve.sh`

**Interfaces:**
- Consumes: `_fm`, `_fm_set`, `_body`, `_provenance`, `_write_fact`, `_kindex`, `_lock`/`_unlock`.
- Produces: `k_resolve <id> [--keep existing|new]` → default `existing`; keeps one side, tombstones the loser body, deletes the `.conflict` file.

- [ ] **Step 1: Write the failing test**

Create `tests/test_14_knowledge_resolve.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
F="$DIR/knowledge/facts"

"$RELAY" knowledge add --fact --id x "original body about release.sh" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact --id x "totally different claim about auth jwt" --dir "$DIR" >/dev/null
assert_file "$F/x.conflict"

# resolve --keep new → fact body becomes the new claim; conflict cleared; loser tombstoned
out="$("$RELAY" knowledge resolve x --keep new --dir "$DIR")"
assert_contains "$out" "resolved: x"
[ -f "$F/x.conflict" ] && { echo "FAIL: conflict file should be gone"; exit 1; }
assert_contains "$(cat "$F/x.md")" "auth jwt"
assert_file "$F/superseded/x.original.md"

# resolve default (keep existing) on a second conflict
"$RELAY" knowledge add --fact --id y "keep me" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact --id y "discard this divergent one" --dir "$DIR" >/dev/null
"$RELAY" knowledge resolve y --dir "$DIR" >/dev/null
assert_contains "$(cat "$F/y.md")" "keep me"
[ -f "$F/y.conflict" ] && { echo "FAIL: conflict file should be gone"; exit 1; }
assert_file "$F/superseded/y.losing.md"   # the discarded side is tombstoned, not lost
pass "knowledge resolve: keep new / keep existing, tombstone loser"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_14_knowledge_resolve.sh`
Expected: FAIL (`resolve` unknown subcommand).

- [ ] **Step 3: Add `resolve` dispatch and `k_resolve`**

In `cmd_knowledge`'s `case`, add `resolve) k_resolve "$@";;` above the `*)` line. Add `k_resolve` before `cmd_knowledge`:

```bash
k_resolve() {
  local keep="existing" id="" rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep) keep="$2"; shift 2;;
      *) rest+=("$1"); shift;;
    esac
  done
  set -- ${rest[@]+"${rest[@]}"}
  id="$(_slugify "${1:-}")"
  local f="$DATA/knowledge/facts/$id.md" cf="$DATA/knowledge/facts/$id.conflict"
  [ -f "$cf" ] || { echo "relay: no pending conflict for: $id" >&2; return 1; }
  _lock || return 1
  mkdir -p "$DATA/knowledge/facts/superseded"
  if [ "$keep" = new ]; then
    cp "$f" "$DATA/knowledge/facts/superseded/$id.original.md"
    _set_body "$f" "$(cat "$cf")"
    _fm_set "$f" last_confirmed "$(date +%F)"
  else
    printf -- '---\nid: %s\nkind: fact\nstatus: superseded\nsource: %s\n---\n%s\n' \
      "$id" "$(_provenance)" "$(cat "$cf")" > "$DATA/knowledge/facts/superseded/$id.losing.md"
  fi
  rm -f "$cf"
  _kindex
  _unlock
  echo "resolved: $id (kept $keep)"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_14_knowledge_resolve.sh`
Expected: `PASS: knowledge resolve: keep new / keep existing, tombstone loser`

- [ ] **Step 5: Commit**

```bash
git add relay.sh tests/test_14_knowledge_resolve.sh
git commit -m "feat(relay): knowledge resolve — settle fact conflicts, tombstone loser"
```

---

## Task 5: `knowledge list` — derived index + drift/conflict flags

**Files:**
- Modify: `relay.sh` (dispatch `list`; add `k_list`)
- Test: `tests/test_15_knowledge_list.sh`

**Interfaces:**
- Consumes: `_kindex`, `_fm`, `_lock`/`_unlock`.
- Produces: `k_list` → rebuilds the derived index under lock, prints active facts/lessons with `confirmed`/`seen`, flags pending conflicts and graduated-but-deleted drift.

- [ ] **Step 1: Write the failing test**

Create `tests/test_15_knowledge_list.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

"$RELAY" knowledge add --fact   --id deploy "ship via release.sh" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --lesson --id types-first "regen types first" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact   --id deploy "auth jwt session different" --dir "$DIR" >/dev/null   # conflict

out="$("$RELAY" knowledge list --dir "$DIR")"
assert_contains "$out" "deploy"
assert_contains "$out" "types-first"
assert_contains "$out" "conflict"

# manually corrupt the index, then list rebuilds it from files (drift self-heals)
printf 'garbage\n' > "$DIR/knowledge/index.md"
"$RELAY" knowledge list --dir "$DIR" >/dev/null
assert_contains "$(cat "$DIR/knowledge/index.md")" "lesson · types-first"
pass "knowledge list: active entries, conflict flag, index self-heal"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_15_knowledge_list.sh`
Expected: FAIL (`list` unknown subcommand).

- [ ] **Step 3: Add `list` dispatch and `k_list`**

In `cmd_knowledge`'s `case`, add `list) k_list "$@";;`. Add `k_list`:

```bash
k_list() {
  local kd="$DATA/knowledge" f id g
  _lock || return 1
  _kindex
  _unlock
  [ -d "$kd" ] || { echo "(no knowledge yet)"; return 0; }
  echo "Facts:"
  for f in "$kd"/facts/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"
    printf '  - %s (confirmed:%s)%s\n' "$id" "$(_fm "$f" confirmed)" \
      "$([ -f "$kd/facts/$id.conflict" ] && printf '  ⚠ conflict — resolve %s' "$id")"
  done
  echo "Lessons (active):"
  for f in "$kd"/lessons/*.md; do
    [ -e "$f" ] || continue
    printf '  - %s (seen:%s sessions:%s)\n' "$(_fm "$f" id)" "$(_fm "$f" seen)" "$(_fm "$f" sessions)"
  done
  if [ -d "$kd/lessons/graduated" ]; then
    echo "Lessons (graduated):"
    for f in "$kd"/lessons/graduated/*.md; do
      [ -e "$f" ] || continue
      id="$(_fm "$f" id)"; g="$(_fm "$f" graduated_to)"
      if [ -n "$g" ] && [ -f "$g" ] && grep -qF "<!-- relay:learned:$id -->" "$g"; then
        printf '  - %s → %s\n' "$id" "$g"
      else
        printf '  - %s  ⚠ DRIFT: graduated rule missing from %s — re-graduate or supersede\n' "$id" "$g"
      fi
    done
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_15_knowledge_list.sh`
Expected: `PASS: knowledge list: active entries, conflict flag, index self-heal`

- [ ] **Step 5: Commit**

```bash
git add relay.sh tests/test_15_knowledge_list.sh
git commit -m "feat(relay): knowledge list + derived-index self-heal + drift detection"
```

---

## Task 6: `knowledge graduate` — idempotent instruction-block write

This is the most fragile operation (the marked-block editor). It carries a 4-case matrix.

**Files:**
- Modify: `relay.sh` (dispatch `graduate`; add `_instruction_file`, `_block_upsert`, `k_graduate`)
- Test: `tests/test_16_knowledge_graduate.sh`

**Interfaces:**
- Consumes: `_slugify`, `_fm`, `_fm_set`, `_body`, `_kindex`, `_lock`/`_unlock`.
- Produces:
  - `_instruction_file` → path to `$RELAY_INSTRUCTION_FILE`, else `CLAUDE.md`, else `AGENTS.md`, else `$PWD/CLAUDE.md`
  - `_block_upsert <file> <id> <body>` → idempotent insert/replace of an id-keyed block inside the `<!-- relay:learned -->` region
  - `k_graduate <id>` → block write → status flip + `graduated_to` → move to `lessons/graduated/` → index rebuild

- [ ] **Step 1: Write the failing test**

Create `tests/test_16_knowledge_graduate.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
INSTR="$TMP/CLAUDE.md"; export RELAY_INSTRUCTION_FILE="$INSTR"
L="$DIR/knowledge/lessons"

"$RELAY" knowledge add --lesson --id types-first "Regenerate types before call-sites." --dir "$DIR" >/dev/null

# case 1: no region yet → graduate creates region + id-block, moves the lesson
out="$("$RELAY" knowledge graduate types-first --dir "$DIR")"
assert_contains "$out" "graduated: types-first"
assert_contains "$(cat "$INSTR")" "<!-- relay:learned -->"
assert_contains "$(cat "$INSTR")" "<!-- relay:learned:types-first -->"
assert_contains "$(cat "$INSTR")" "Regenerate types before call-sites."
assert_file "$L/graduated/types-first.md"
[ -f "$L/types-first.md" ] && { echo "FAIL: active lesson should have moved"; exit 1; }
assert_contains "$(cat "$L/graduated/types-first.md")" "status: graduated"

# case 2: idempotent — re-running graduate on a graduated id does not duplicate the block
"$RELAY" knowledge graduate types-first --dir "$DIR" >/dev/null 2>&1 || true
count="$(grep -cF "<!-- relay:learned:types-first -->" "$INSTR")"
assert_eq "$count" "1"

# case 3: a SECOND lesson graduates into the SAME region (not a second region)
"$RELAY" knowledge add --lesson --id lint-first "Run the linter before committing." --dir "$DIR" >/dev/null
"$RELAY" knowledge graduate lint-first --dir "$DIR" >/dev/null
assert_eq "$(grep -cF "<!-- relay:learned -->" "$INSTR")" "1"
assert_contains "$(cat "$INSTR")" "<!-- relay:learned:lint-first -->"

# case 4: user hand-edits prose around the markers → region still intact, both ids present
printf '\n## My own notes\nhand-written.\n' >> "$INSTR"
assert_contains "$(cat "$INSTR")" "<!-- relay:learned:types-first -->"
assert_contains "$(cat "$INSTR")" "<!-- relay:learned:lint-first -->"

# case 5: a MULTI-LINE lesson body graduates intact (regression guard — newline must not break the awk block write)
"$RELAY" knowledge add --lesson --id multi "First line of the lesson.
Second line with the why." --dir "$DIR" >/dev/null
"$RELAY" knowledge graduate multi --dir "$DIR" >/dev/null
assert_contains "$(cat "$INSTR")" "First line of the lesson."
assert_contains "$(cat "$INSTR")" "Second line with the why."
pass "knowledge graduate: region create, idempotent, shared region, hand-edit safe, multi-line body"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_16_knowledge_graduate.sh`
Expected: FAIL (`graduate` unknown subcommand).

- [ ] **Step 3: Add graduation helpers and dispatch**

In `cmd_knowledge`'s `case`, add `graduate) k_graduate "$@";;`. Add before `cmd_knowledge`:

```bash
_instruction_file() {
  if [ -n "${RELAY_INSTRUCTION_FILE:-}" ]; then printf '%s' "$RELAY_INSTRUCTION_FILE"; return; fi
  if   [ -f "$PWD/CLAUDE.md" ]; then printf '%s' "$PWD/CLAUDE.md"
  elif [ -f "$PWD/AGENTS.md" ]; then printf '%s' "$PWD/AGENTS.md"
  else printf '%s' "$PWD/CLAUDE.md"; fi
}

_block_upsert() { # file id body  (idempotent; replaces any existing id-block)
  local file="$1" id="$2" body="$3" tmp bodyf
  touch "$file"
  grep -qF "<!-- relay:learned -->" "$file" || \
    printf '\n<!-- relay:learned -->\n<!-- /relay:learned -->\n' >> "$file"
  # Body MUST be passed via a file, not `awk -v`: BSD/POSIX awk rejects a newline
  # inside a -v value, which would hard-fail graduation of any multi-line lesson.
  bodyf="$(mktemp)"; printf '%s\n' "$body" > "$bodyf"
  tmp="$(mktemp)"
  awk -v id="$id" -v bodyf="$bodyf" '
    BEGIN{ s="<!-- relay:learned:"id" -->"; e="<!-- /relay:learned:"id" -->";
           rend="<!-- /relay:learned -->"; skip=0; done=0 }
    {
      if($0==s){ skip=1; next }
      if(skip==1){ if($0==e) skip=0; next }
      if($0==rend && done==0){
        print s; while((getline ln < bodyf) > 0) print ln; close(bodyf); print e; done=1; print; next
      }
      print
    }' "$file" > "$tmp"
  mv "$tmp" "$file"
  rm -f "$bodyf"
}

k_graduate() {
  local id; id="$(_slugify "${1:-}")"
  local f="$DATA/knowledge/lessons/$id.md"
  if [ ! -f "$f" ]; then
    [ -f "$DATA/knowledge/lessons/graduated/$id.md" ] && { echo "already graduated: $id"; return 0; }
    echo "relay: no active lesson: $id" >&2; return 1
  fi
  _lock || return 1
  local target; target="$(_instruction_file)"
  _block_upsert "$target" "$id" "$(_body "$f")"
  _fm_set "$f" status graduated
  _fm_set "$f" graduated_to "$target"
  mkdir -p "$DATA/knowledge/lessons/graduated"
  mv "$f" "$DATA/knowledge/lessons/graduated/$id.md"
  _kindex
  _unlock
  # the one local→committed leak, named at the helper layer (spec §7.2), not just in adapter prose
  echo "note: wrote to $target (a normally-committed file) — local-only learning may now travel; committing it is your choice." >&2
  echo "graduated: $id → $target"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_16_knowledge_graduate.sh`
Expected: `PASS: knowledge graduate: region create, idempotent, shared region, hand-edit safe`

- [ ] **Step 5: Commit**

```bash
git add relay.sh tests/test_16_knowledge_graduate.sh
git commit -m "feat(relay): knowledge graduate — idempotent id-keyed instruction block"
```

---

## Task 7: `knowledge ungraduate` + `knowledge supersede`

**Files:**
- Modify: `relay.sh` (dispatch `ungraduate`, `supersede`; add `_block_remove`, `k_ungraduate`, `k_supersede`)
- Test: `tests/test_17_knowledge_ungraduate.sh`

**Interfaces:**
- Consumes: `_slugify`, `_fm`, `_kindex`, `_instruction_file`, `_lock`/`_unlock`.
- Produces:
  - `_block_remove <file> <id>` → idempotently delete the id-block from the region
  - `k_ungraduate <id>` → remove block + tombstone the graduated lesson to `lessons/superseded/`
  - `k_supersede <id>` → tombstone an active fact or lesson to its `superseded/` dir

- [ ] **Step 1: Write the failing test**

Create `tests/test_17_knowledge_ungraduate.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
INSTR="$TMP/CLAUDE.md"; export RELAY_INSTRUCTION_FILE="$INSTR"
L="$DIR/knowledge/lessons"

"$RELAY" knowledge add --lesson --id types-first "Regen types first." --dir "$DIR" >/dev/null
"$RELAY" knowledge graduate types-first --dir "$DIR" >/dev/null
assert_contains "$(cat "$INSTR")" "<!-- relay:learned:types-first -->"

# ungraduate removes the block lines (idempotent) and tombstones the lesson
out="$("$RELAY" knowledge ungraduate types-first --dir "$DIR")"
assert_contains "$out" "ungraduated: types-first"
[ "$(grep -cF "<!-- relay:learned:types-first -->" "$INSTR")" = "0" ] || { echo "FAIL: block not removed"; exit 1; }
assert_file "$L/superseded/types-first.md"
# idempotent second call
"$RELAY" knowledge ungraduate types-first --dir "$DIR" >/dev/null 2>&1 || true
assert_eq "$(grep -cF "<!-- relay:learned:types-first -->" "$INSTR")" "0"

# supersede an active fact
"$RELAY" knowledge add --fact --id pin-dep "pin dep to 4.1 for now" --dir "$DIR" >/dev/null
"$RELAY" knowledge supersede pin-dep --dir "$DIR" >/dev/null
assert_file "$DIR/knowledge/facts/superseded/pin-dep.md"
[ -f "$DIR/knowledge/facts/pin-dep.md" ] && { echo "FAIL: fact should be tombstoned"; exit 1; }
pass "knowledge ungraduate + supersede"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_17_knowledge_ungraduate.sh`
Expected: FAIL (`ungraduate` unknown subcommand).

- [ ] **Step 3: Add the dispatch and helpers**

In `cmd_knowledge`'s `case`, add `ungraduate) k_ungraduate "$@";;` and `supersede) k_supersede "$@";;`. Add:

```bash
_block_remove() { # file id  (idempotent)
  local file="$1" id="$2" tmp
  [ -f "$file" ] || return 0
  tmp="$(mktemp)"
  awk -v id="$id" '
    BEGIN{ s="<!-- relay:learned:"id" -->"; e="<!-- /relay:learned:"id" -->"; skip=0 }
    { if($0==s){skip=1; next} if(skip==1){ if($0==e) skip=0; next } print }' "$file" > "$tmp"
  mv "$tmp" "$file"
}

k_ungraduate() {
  local id; id="$(_slugify "${1:-}")"
  local g="$DATA/knowledge/lessons/graduated/$id.md"
  _lock || return 1
  local target; target="$(_instruction_file)"
  _block_remove "$target" "$id"
  if [ -f "$g" ]; then
    mkdir -p "$DATA/knowledge/lessons/superseded"
    mv "$g" "$DATA/knowledge/lessons/superseded/$id.md"
  fi
  _kindex
  _unlock
  echo "ungraduated: $id"
}

k_supersede() {
  local id; id="$(_slugify "${1:-}")"
  _lock || return 1
  local moved=0 kind
  for kind in facts lessons; do
    local f="$DATA/knowledge/$kind/$id.md"
    if [ -f "$f" ]; then
      mkdir -p "$DATA/knowledge/$kind/superseded"
      mv "$f" "$DATA/knowledge/$kind/superseded/$id.md"
      rm -f "$DATA/knowledge/facts/$id.conflict"
      moved=1
    fi
  done
  _kindex
  _unlock
  [ "$moved" = 1 ] && echo "superseded: $id" || { echo "relay: no active entry: $id" >&2; return 1; }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_17_knowledge_ungraduate.sh`
Expected: `PASS: knowledge ungraduate + supersede`

- [ ] **Step 5: Commit**

```bash
git add relay.sh tests/test_17_knowledge_ungraduate.sh
git commit -m "feat(relay): knowledge ungraduate + supersede (retire graduated/active entries)"
```

---

## Task 8: `knowledge prune` — gated staleness review

**Files:**
- Modify: `relay.sh` (dispatch `prune`; add `k_prune`)
- Test: `tests/test_18_knowledge_prune.sh`

**Interfaces:**
- Consumes: `_fm`, `_days_since`, `k_supersede`, `_lock`/`_unlock`.
- Produces: `k_prune [--yes]` → dry-run lists facts past their freshness window (ttl, else `RELAY_FACT_STALE_DAYS`); with `--yes`, supersedes them.

- [ ] **Step 1: Write the failing test**

Create `tests/test_18_knowledge_prune.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
F="$DIR/knowledge/facts"

"$RELAY" knowledge add --fact --id fresh "recently true" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact --id old-ttl "sprint is X" --dir "$DIR" >/dev/null

# backdate old-ttl's last_confirmed 30 days and give it ttl:14 → expired
old="$(date -v-30d +%F 2>/dev/null || date -d '30 days ago' +%F)"
tmp="$(mktemp)"; sed -e "s/^last_confirmed: .*/last_confirmed: $old/" -e "s/^ttl: .*/ttl: 14/" "$F/old-ttl.md" > "$tmp"; mv "$tmp" "$F/old-ttl.md"

# dry run proposes old-ttl, not fresh; writes nothing
out="$("$RELAY" knowledge prune --dir "$DIR")"
assert_contains "$out" "old-ttl"
assert_file "$F/fresh.md"; assert_file "$F/old-ttl.md"

# --yes applies
"$RELAY" knowledge prune --yes --dir "$DIR" >/dev/null
assert_file "$F/superseded/old-ttl.md"
assert_file "$F/fresh.md"
pass "knowledge prune: gated staleness review (dry-run + --yes)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_18_knowledge_prune.sh`
Expected: FAIL (`prune` unknown subcommand).

- [ ] **Step 3: Add `prune` dispatch and `k_prune`**

In `cmd_knowledge`'s `case`, add `prune) k_prune "$@";;`. Add:

```bash
k_prune() {
  local apply=0; [ "${1:-}" = "--yes" ] && apply=1
  local kd="$DATA/knowledge" f id ttl last age limit stale=""
  [ -d "$kd/facts" ] || { echo "(no facts)"; return 0; }
  for f in "$kd"/facts/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"; ttl="$(_fm "$f" ttl)"; last="$(_fm "$f" last_confirmed)"
    age="$(_days_since "$last")"
    if [ "$ttl" != "none" ] && [ -n "$ttl" ]; then limit="$ttl"; else limit="$RELAY_FACT_STALE_DAYS"; fi
    [ "$age" -gt "$limit" ] && stale="$stale$id "
  done
  if [ -z "$stale" ]; then echo "(nothing stale)"; return 0; fi
  if [ "$apply" = 1 ]; then
    for id in $stale; do k_supersede "$id" >/dev/null; done
    echo "pruned: $stale"
  else
    echo "Stale facts (past freshness window) — run 'relay knowledge prune --yes' to retire:"
    for id in $stale; do echo "  - $id"; done
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_18_knowledge_prune.sh`
Expected: `PASS: knowledge prune: gated staleness review (dry-run + --yes)`

- [ ] **Step 5: Commit**

```bash
git add relay.sh tests/test_18_knowledge_prune.sh
git commit -m "feat(relay): knowledge prune — gated staleness review"
```

---

## Task 9: Load injection — facts + active lessons, never-silent caps

**Files:**
- Modify: `relay.sh` (add `_load_knowledge`; call it inside `cmd_load` after the latest body, before the handoff index emit)
- Test: `tests/test_19_knowledge_load.sh`

**Interfaces:**
- Consumes: `_fm`, `_body`, `_days_since` (T1); `_instruction_file` (T6, for the graduated-block nudge); `RELAY_FACTS_CAP`, `RELAY_LESSONS_CAP`, `RELAY_FACT_STALE_DAYS`, `RELAY_GRADUATED_SOFT`.
- Produces: `_load_knowledge` → prints the facts + active-lessons block (ranked, capped, with explicit "N of M shown" on truncation, ttl/conflict nudges, and an oversized-graduated-block nudge); empty when no knowledge exists.
- Integration: `cmd_load` appends `_load_knowledge` output into `out` so it flows through both the text and `--format codex` paths unchanged.

- [ ] **Step 1: Write the failing test**

Create `tests/test_19_knowledge_load.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

printf '## Summary\nhandoff body\n' | "$RELAY" save --dir "$DIR" --digest "d"
"$RELAY" knowledge add --fact   --id deploy "Deploys ship via release.sh" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --lesson --id types-first "Regen types before call-sites" --dir "$DIR" >/dev/null

out="$("$RELAY" load --dir "$DIR")"
assert_contains "$out" "handoff body"          # handoff still present
assert_contains "$out" "facts"                 # knowledge section header
assert_contains "$out" "Deploys ship via release.sh"
assert_contains "$out" "Regen types before call-sites"   # lesson BODY (load emits bodies, not ids)

# graduated lessons are NOT injected (they live in the instruction file) — assert the BODY is absent
export RELAY_INSTRUCTION_FILE="$TMP/CLAUDE.md"
"$RELAY" knowledge graduate types-first --dir "$DIR" >/dev/null 2>&1
out="$("$RELAY" load --dir "$DIR")"
[ -z "$(printf '%s' "$out" | grep -F 'Regen types before call-sites' || true)" ] || { echo "FAIL: graduated lesson double-injected"; exit 1; }

# oversized graduated-block nudge fires (1 graduated rule, soft cap forced to 1)
out="$(RELAY_GRADUATED_SOFT=1 "$RELAY" load --dir "$DIR")"
assert_contains "$out" "graduated rules"

# over-cap → explicit "N of M shown", never silent
RELAY_FACTS_CAP=8 "$RELAY" knowledge add --fact --id f2 "second fact about something else entirely here now" --dir "$DIR" >/dev/null
out="$(RELAY_FACTS_CAP=8 "$RELAY" load --dir "$DIR")"
assert_contains "$out" "of"
assert_contains "$out" "not loaded"

# codex format stays valid JSON with knowledge present
out="$("$RELAY" load --dir "$DIR" --format codex)"
assert_contains "$out" '"systemMessage"'
assert_contains "$out" '"hookEventName":"SessionStart"'
pass "knowledge load: inject, no graduated double-inject, non-silent cap, codex JSON"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_19_knowledge_load.sh`
Expected: FAIL (no knowledge section in load output).

- [ ] **Step 3: Add `_load_knowledge` and call it from `cmd_load`**

Add `_load_knowledge` before `cmd_load`:

```bash
_load_knowledge() {
  local kd="$DATA/knowledge" f id body conf last ttl age
  [ -d "$kd/facts" ] || [ -d "$kd/lessons" ] || return 0
  local out="" tmp sorted total shown block exp=0 conflicts=0 today
  today="$(date +%F)"

  # ---- FACTS: rank by confirmed, then recency ----
  tmp="$(mktemp)"
  for f in "$kd"/facts/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"; conf="$(_fm "$f" confirmed)"; last="$(_fm "$f" last_confirmed)"; ttl="$(_fm "$f" ttl)"
    body="$(_body "$f" | tr '\n' ' ')"
    age="$(_days_since "$last")"
    local lim; if [ "$ttl" != none ] && [ -n "$ttl" ]; then lim="$ttl"; else lim="$RELAY_FACT_STALE_DAYS"; fi
    [ "$age" -gt "$lim" ] && exp=$(( exp + 1 ))
    [ -f "$kd/facts/$id.conflict" ] && conflicts=$(( conflicts + 1 ))
    printf '%03d\t%09d\t- %s (confirmed:%s)\n' "${conf:-1}" "$(( 999999 - age ))" "$body" "${conf:-1}" >> "$tmp"
  done
  if [ -s "$tmp" ]; then
    total="$(grep -c . "$tmp" || true)"
    sorted="$(sort -t$'\t' -k1,1nr -k2,2nr "$tmp")"   # explicit numeric keys: confirmed desc, then recency desc
    block="$(printf '%s\n' "$sorted" | awk -v cap="$RELAY_FACTS_CAP" -F'\t' '
      { line=$3; n=split(line,w," "); if(words+n>cap && nl>0) next; words+=n; nl++; print line }')"
    shown="$(printf '%s\n' "$block" | grep -c . || true)"
    out="${out}## What this repo knows — facts"$'\n'
    [ "$shown" -lt "$total" ] && out="${out}⚠ $shown of $total facts shown — $(( total - shown )) not loaded may include load-bearing truths; open .session-log/knowledge/facts/"$'\n'
    out="${out}${block}"$'\n'
    [ "$exp" -gt 0 ] && out="${out}($exp fact(s) past freshness window — run: relay knowledge prune)"$'\n'
    [ "$conflicts" -gt 0 ] && out="${out}(⚠ $conflicts fact conflict(s) pending — run: relay knowledge resolve <id>)"$'\n'
  fi
  rm -f "$tmp"

  # ---- LESSONS (active): rank by seen ----
  tmp="$(mktemp)"
  for f in "$kd"/lessons/*.md; do
    [ -e "$f" ] || continue
    body="$(_body "$f" | tr '\n' ' ')"
    printf '%05d\t- %s\n' "$(_fm "$f" seen)" "$body" >> "$tmp"
  done
  if [ -s "$tmp" ]; then
    total="$(grep -c . "$tmp" || true)"
    sorted="$(sort -t$'\t' -k1,1nr "$tmp")"   # explicit numeric key: seen desc
    block="$(printf '%s\n' "$sorted" | awk -v cap="$RELAY_LESSONS_CAP" -F'\t' '
      { line=$2; n=split(line,w," "); if(words+n>cap && nl>0) next; words+=n; nl++; print line }')"
    shown="$(printf '%s\n' "$block" | grep -c . || true)"
    out="${out}## What this repo knows — lessons"$'\n'
    [ "$shown" -lt "$total" ] && out="${out}⚠ $shown of $total lessons shown — open .session-log/knowledge/lessons/"$'\n'
    out="${out}${block}"$'\n'
  fi
  rm -f "$tmp"

  # ---- oversized graduated-block nudge (spec §7.1 — the uncapped instruction surface) ----
  local instr gcount
  instr="$(_instruction_file)"
  if [ -f "$instr" ]; then
    gcount="$(grep -cF '<!-- relay:learned:' "$instr" 2>/dev/null || printf 0)"
    if [ "${gcount:-0}" -ge "${RELAY_GRADUATED_SOFT:-8}" ]; then
      out="${out}(⚠ $gcount graduated rules in $(basename "$instr") — review/consolidate via: relay knowledge list / ungraduate)"$'\n'
    fi
  fi

  [ -n "$out" ] && printf '%s' "$out"
}
```

In `cmd_load`, after the line that appends the latest body to `out` (the `if/else` that sets `out="$out$(cat "$latest")"` etc.) and **before** the `[ -f "$idx" ] && out="$out"…index` line, insert:

```bash
  local kblock; kblock="$(_load_knowledge)"
  [ -n "$kblock" ] && out="$out"$'\n\n'"$kblock"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_19_knowledge_load.sh`
Expected: `PASS: knowledge load: inject, no graduated double-inject, non-silent cap, codex JSON`

- [ ] **Step 5: Run the full suite (regression — load is shared)**

Run: `for t in tests/test_*.sh; do bash "$t" || exit 1; done`
Expected: all `PASS` (especially `test_06_load.sh` and `test_08_codex_adapter.sh`).

- [ ] **Step 6: Commit**

```bash
git add relay.sh tests/test_19_knowledge_load.sh
git commit -m "feat(relay): inject facts + active lessons at load, never-silent caps"
```

---

## Task 10: `knowledge why` + `knowledge export`

**Files:**
- Modify: `relay.sh` (dispatch `why`, `export`; add `k_why`, `k_export`)
- Test: `tests/test_20_knowledge_why_export.sh`

**Interfaces:**
- Consumes: `_slugify`, `_fm`, `_body`.
- Produces:
  - `k_why <id>` → print the entry plus the referenced handoff section if present
  - `k_export` → concat all active facts + lessons into one shareable markdown stream on stdout

- [ ] **Step 1: Write the failing test**

Create `tests/test_20_knowledge_why_export.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

printf '## Summary\nthe origin session\n' | "$RELAY" save --dir "$DIR" --digest "d"
"$RELAY" knowledge add --fact   --id deploy "ship via release.sh" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --lesson --id types-first "regen types first" --dir "$DIR" >/dev/null

# why prints the entry + its provenance source
out="$("$RELAY" knowledge why deploy --dir "$DIR")"
assert_contains "$out" "ship via release.sh"
assert_contains "$out" "source:"

# export concatenates active entries
out="$("$RELAY" knowledge export --dir "$DIR")"
assert_contains "$out" "ship via release.sh"
assert_contains "$out" "regen types first"
pass "knowledge why + export"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_20_knowledge_why_export.sh`
Expected: FAIL (`why` unknown subcommand).

- [ ] **Step 3: Add `why`/`export` dispatch and helpers**

In `cmd_knowledge`'s `case`, add `why) k_why "$@";;` and `export) k_export "$@";;`. Add:

```bash
k_why() {
  local id; id="$(_slugify "${1:-}")"
  local f="" k
  for k in facts lessons; do [ -f "$DATA/knowledge/$k/$id.md" ] && f="$DATA/knowledge/$k/$id.md"; done
  [ -n "$f" ] || { echo "relay: no entry: $id" >&2; return 1; }
  echo "--- entry ---"; cat "$f"
  local src; src="$(_fm "$f" source)"
  local hist="${src%%#*}"
  if [ -n "$hist" ] && [ -f "$DATA/$hist" ]; then
    echo; echo "--- came from $src ---"; sed -n '1,40p' "$DATA/$hist"
  fi
}

k_export() {
  local kd="$DATA/knowledge" f
  echo "# Relay knowledge pack — $(date +%F)"
  echo; echo "## Facts"
  for f in "$kd"/facts/*.md; do [ -e "$f" ] || continue; echo; echo "### $(_fm "$f" id)"; _body "$f"; done
  echo; echo "## Lessons"
  for f in "$kd"/lessons/*.md; do [ -e "$f" ] || continue; echo; echo "### $(_fm "$f" id)"; _body "$f"; done
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_20_knowledge_why_export.sh`
Expected: `PASS: knowledge why + export`

- [ ] **Step 5: Commit**

```bash
git add relay.sh tests/test_20_knowledge_why_export.sh
git commit -m "feat(relay): knowledge why (provenance audit) + export (shareable pack)"
```

---

## Task 11: Adapters — `/relay-learn` command/skill + capture instructions

**Files:**
- Create: `adapters/claude-code/commands/relay-learn.md`
- Create: `adapters/codex/skills/relay-learn/SKILL.md`
- Modify: `adapters/claude-code/CLAUDE.relay.md`
- Modify: `adapters/codex/AGENTS.relay.md`
- Modify: `adapters/claude-code/commands/session-save.md`
- Modify: `adapters/codex/skills/session-save/SKILL.md`
- Test: `tests/test_21_adapter_bundle.sh`

**Interfaces:**
- Consumes: the `relay.sh knowledge add` CLI (Tasks 1–3); the bundler's `find adapters -type f` auto-embedding; the installer's `wire_cc`/`wire_codex` which copy `commands/*.md` and `skills/*`.
- Produces: the two new adapter files (auto-bundled, auto-wired) and the capture instructions in the L2 + save files.

- [ ] **Step 1: Write the failing test**

Create `tests/test_21_adapter_bundle.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"

# the new adapter files exist
assert_file "$SRC/adapters/claude-code/commands/relay-learn.md"
assert_file "$SRC/adapters/codex/skills/relay-learn/SKILL.md"

# bundle regenerates and offline-installs into a fresh CC repo, wiring /relay-learn
( cd "$SRC" && bash bundle.sh )
assert_file "$SRC/dist/install.sh"
TMP="$(mktemp -d)"; mkdir -p "$TMP/.claude"; ( cd "$TMP" && git init -q )
( cd "$TMP" && bash "$SRC/dist/install.sh" )
assert_file "$TMP/.claude/commands/relay-learn.md"
assert_file "$TMP/.relay/relay.sh"

# the wired tool can capture knowledge end to end
( cd "$TMP" && .relay/relay.sh knowledge add --lesson --id e2e "end to end works" --dir "$TMP/.session-log" >/dev/null )
assert_file "$TMP/.session-log/knowledge/lessons/e2e.md"
pass "adapter: /relay-learn wired + bundle offline install + e2e capture"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_21_adapter_bundle.sh`
Expected: FAIL (new adapter files missing).

- [ ] **Step 3: Create the CC `/relay-learn` command**

Create `adapters/claude-code/commands/relay-learn.md`:

```markdown
<!-- adapters/claude-code/commands/relay-learn.md -->
---
description: Record a durable fact or lesson about this repo into Relay knowledge
---
Capture a single durable piece of knowledge about THIS repo for future sessions.

1. Decide the kind:
   - **Fact** — a durable truth about the repo (a command, a path, a gotcha).
   - **Lesson** — a behavioral pattern ("when X, prefer Y, because Z").
2. For a fact, first check for an existing match so you reuse its id instead of
   duplicating:

   ```bash
   "$CLAUDE_PROJECT_DIR/.relay/relay.sh" knowledge add --fact --near '<the fact text>' \
     --dir "$CLAUDE_PROJECT_DIR/.session-log"
   ```
3. Write it (reuse a surfaced id, or coin a short stable kebab-case slug). Add
   `--ttl <days>` to a fact that is only true for a while (e.g. the current sprint);
   omit it for durable truths:

   ```bash
   "$CLAUDE_PROJECT_DIR/.relay/relay.sh" knowledge add --fact --id <slug> '<fact text>' \
     --dir "$CLAUDE_PROJECT_DIR/.session-log"
   # time-bound fact: "$CLAUDE_PROJECT_DIR/.relay/relay.sh" knowledge add --fact --id current-sprint --ttl 14 '...' --dir ...
   # or a lesson:
   "$CLAUDE_PROJECT_DIR/.relay/relay.sh" knowledge add --lesson --id <slug> '<lesson text>' \
     --dir "$CLAUDE_PROJECT_DIR/.session-log"
   ```
4. If the tool reports a lesson is graduation-ready, offer (one line) to run
   `knowledge graduate <slug>` — never graduate without the user's okay.
```

- [ ] **Step 4: Create the Codex `$relay-learn` skill**

Create `adapters/codex/skills/relay-learn/SKILL.md`:

```markdown
<!-- adapters/codex/skills/relay-learn/SKILL.md -->
---
name: relay-learn
description: Record a durable fact or lesson about this repo into Relay knowledge
---
Capture one durable piece of knowledge about THIS repo for future sessions.

1. Fact = durable repo truth; Lesson = behavioral pattern ("when X, prefer Y").
2. For a fact, check for a match first (reuse the id, don't duplicate):

   ```bash
   "${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --fact --near '<fact text>' \
     --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log"
   ```
3. Write it with a short stable kebab-case `--id` (a fact reuses any id surfaced above):

   ```bash
   "${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --fact --id <slug> '<fact text>' \
     --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log"
   # or a lesson:
   "${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --lesson --id <slug> '<lesson text>' \
     --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log"
   ```
4. If a lesson is graduation-ready, offer to `knowledge graduate <slug>` — only with the user's okay.
```

- [ ] **Step 5: Add the capture step to both save flows and L2 files**

Append to `adapters/claude-code/commands/session-save.md` (after step 3):

```markdown
4. Then capture durable knowledge from this session (skip if none): for each
   permanent repo truth run `knowledge add --fact --near` then `--fact --id <slug>`;
   for each behavioral lesson run `knowledge add --lesson --id <slug>`. Use
   `"$CLAUDE_PROJECT_DIR/.relay/relay.sh"` and `--dir "$CLAUDE_PROJECT_DIR/.session-log"`.
   If the tool says a lesson is graduation-ready, offer graduation in one line.
```

Append to `adapters/codex/skills/session-save/SKILL.md` (after step 3):

```markdown
4. Then capture durable knowledge (skip if none): facts via
   `knowledge add --fact --near` then `--fact --id <slug>`; lessons via
   `knowledge add --lesson --id <slug>`, using `"${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh"`
   and `--dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log"`. Offer graduation only when prompted and approved.
```

Append one line to `adapters/claude-code/CLAUDE.relay.md`:

```markdown
At wrap-up, also capture durable facts/lessons with `/relay-learn` (or inline
`knowledge add`), and surface any graduation-ready lesson for the user to approve.
```

Append one line to `adapters/codex/AGENTS.relay.md`:

```markdown
At wrap-up, also capture durable facts/lessons with `$relay-learn` (or inline
`knowledge add`), and surface any graduation-ready lesson for the user to approve.
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/test_21_adapter_bundle.sh`
Expected: `PASS: adapter: /relay-learn wired + bundle offline install + e2e capture`

- [ ] **Step 7: Run the FULL suite + regenerate the bundle**

Run: `for t in tests/test_*.sh; do bash "$t" || exit 1; done && bash bundle.sh`
Expected: all `PASS`; `wrote dist/install.sh`.

- [ ] **Step 8: Commit**

```bash
git add adapters tests/test_21_adapter_bundle.sh dist/install.sh
git commit -m "feat(relay): /relay-learn adapter + capture-on-save instructions; rebuild bundle"
```

---

## Task 12: Docs + README surface

**Files:**
- Modify: `README.md` (document the knowledge layer in the existing terse style)
- Test: none (doc-only); verified by the full suite still passing.

- [ ] **Step 1: Add a "Learn" subsection to `README.md`**

After the existing `## Use` section, add:

```markdown
## Learn (durable knowledge)

Beyond per-session handoffs, Relay accumulates durable, local-only knowledge:

- **Facts** — truths about the repo. **Lessons** — behavioral patterns that
  reinforce on recurrence and, after recurring across 3 distinct sessions,
  can graduate into `CLAUDE.md`/`AGENTS.md` (gated — the agent asks first).
- Captured at save, or any time via `/relay-learn` (`$relay-learn` on Codex).
- Loaded automatically at session start, ranked and budget-capped — truncation
  is never silent.

Inspect or curate it: `relay.sh knowledge list | why <id> | prune | export`.
All data lives in `.session-log/knowledge/` (gitignored).
```

- [ ] **Step 2: Run the full suite (sanity)**

Run: `for t in tests/test_*.sh; do bash "$t" || exit 1; done`
Expected: all `PASS`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(relay): document the knowledge (learning + memory) layer"
```

---

## Self-review

**Spec coverage** (against `2026-06-22-relay-learning-design.md`):

| Spec section | Task(s) |
|---|---|
| §5 per-entry files + derived index | T1 (`_kindex`, helpers), T5 (rebuild/self-heal) |
| §5.1 index as derived cache (R4) | T1 `_kindex`; T9 load reads files directly (drift can't reach agent); T5 self-heal |
| §5.2 schemas + provenance | T1 (`_write_lesson`,`_provenance`), T2 (`_write_fact`) |
| §6.1 fact `--id` contract (R1) | T2 |
| §6.2 `--near` (R2 mitigation) | T3 |
| §6.3 confirm vs conflict (R2) | T2 (raise), T4 (resolve) |
| §7 lesson lifecycle + sessions gate (R6) | T1 (sessions gate), T6 (graduate), T7 (ungraduate/supersede) |
| §7.1 honest budget framing | T9 (graduated not injected); README T12 |
| §8 facts lifecycle (confirm/ttl/prune) | T2, T8, T9 (ttl nudge) |
| §9 never-silent load (R3) | T9 |
| §10 adapters | T11 |
| §11 command surface | T1–T10 (all subcommands) |
| §12 repo impact | T11 (gitignore unchanged; graduation = the one committed leak) |
| §13 sequencing (index→id→add→load→graduate→rest) | T1→T2/T3→…→T9→T6→T7/T8 |
| §14 tests | T1–T11 each ship a test |

No spec section is unimplemented.

**Placeholder scan:** every code step contains complete bash and complete test bodies; no TBD/TODO/"similar to". ✔

**Type/name consistency:** helper names are defined once and referenced by exact signature in later Interfaces blocks — `_fm`, `_fm_set`, `_body`, `_set_body`, `_slugify`, `_provenance`, `_days_since`, `_kindex`, `_write_fact`, `_write_lesson`, `_dice`, `_similar`, `_k_near`, `_block_upsert`, `_block_remove`, `_instruction_file`, `_load_knowledge`, and the `k_*` subcommands. The `knowledge` dispatch `case` accumulates one arm per task (add, resolve, list, graduate, ungraduate, supersede, prune, why, export) — verify the final `case` lists all nine before T12.

**Known portability watch-items for the implementer** (all handled in-plan, restated so they aren't a surprise):
- Empty-array expansion uses `${arr[@]+"${arr[@]}"}` (bash 3.2 + `set -u`).
- `date` backdating in tests uses `date -v-Nd … || date -d 'N days ago' …` (BSD-first, matches `test_06`).
- `_body`/`_set_body`/`_block_*` are whole-file awk rewrites to a `mktemp` then `mv` — atomic, no in-place surgery.
- Globs are guarded with `[ -e "$f" ] || continue` because bash 3.2 has no `nullglob` here.
- **A multi-line body must never be passed via `awk -v`** (BSD awk rejects an embedded newline) — `_block_upsert` reads the body from a temp file via `getline`.
- Functions that end on a `[ … ] && echo` (notably `_k_add_lesson`) end with `return 0` so a false test can't abort the caller under `set -e`.
- `sort` uses explicit numeric keys (`-t$'\t' -k1,1nr [-k2,2nr]`), never bare `-rk1`, which on BSD `sort` extends the key to end-of-line.
- Complexity note: the plan's "load reads entry files directly" makes the read path **O(entry-files)**, superseding the spec's §9 O(index) read claim — deliberate, immaterial at this store's scale, and the price of making index↔load drift structurally impossible. Fact ranking is `confirmed` desc then recency desc (a tiered approximation of the spec's `confirmed × recency`, more predictable and stable under fixed-width keys).

> **2026-06-22 post-verification revision.** A four-agent adversarial review (bash-correctness, TDD-logic, spec-coverage, interface-consistency) executed the assembled `relay.sh` and found two blockers and four coverage/correctness gaps, now fixed in this plan: (1) `_k_add_lesson` trailing-`&&` exit-1 → `return 0` + `if`-block; (2) `_block_upsert` newline-in-`awk -v` → temp-file `getline`; (3) BSD `sort` key precision; (4) Task-9 test asserted ids where load emits bodies → assert bodies; (5) inert TTL → a real `--ttl` flag (T2) + test; (6) missing oversized-graduated-block nudge (spec §7.1) → added to `_load_knowledge` (T9) + assertion. Also added: distinct-session gate coverage (T1), keep-existing tombstone assertion (T4), multi-line graduation regression guard (T6), helper-layer committed-file warning (T6). The interface-consistency reviewer returned SHIP unchanged (dispatch arms, insertion points, signatures, bundler all verified by execution).
