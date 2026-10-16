# Relay Knowledge Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop Relay from losing knowledge on write, make the knowledge it holds actually reach (and get reinforced by) the agent, and make the Codex adapter load the handoff at all.

**Architecture:** Every change lands in the existing deterministic core (`relay.sh`), the installer (`install.sh`), and the per-harness adapter text under `adapters/`. No new subcommands. Each task adds one regression test file under `tests/` in the existing zero-dependency style (`tests/helper.sh` asserts) and rebundles `dist/install.sh`.

**Tech Stack:** bash (must run on macOS bash 3.2 and Ubuntu bash 5), POSIX awk/sed/grep, optional jq or python3 in the installer only (existing fallback pattern).

**Spec:** No separate spec file. The requirements come from the 2026-10-16 review of this repo and the measurements below, with the choices Jeremy made in that session.

### Background (measured 2026-10-16 across the 9 repos that have Relay)

- 11 knowledge entries in product-almanac and product-forge have the literal body `--body` or `--text`: an agent passed a flag `knowledge add` doesn't know, the flag was stored as the body, and the real text was lost. An unquoted body is silently cut to its first word for the same reason.
- About 110 lessons exist; none has reached `sessions >= 3` organically. Pairwise similarity between lessons tops out at 32%, so these are not duplicates. They never get reinforced because session-start load prints bodies **without ids** (`relay.sh:156`, `relay.sh:178`) and no skill tells the agent to re-assert a loaded lesson.
- product-almanac loads 8 of 50 facts and 6 of 47 lessons; everything past the 400-word budget is invisible to the agent.
- A corrected fact whose wording is close to the old one (Dice >= 50) is counted as a confirmation and the **old** body is kept (`relay.sh:373-377`).
- 6 of 9 installs run an outdated `relay.sh`; nothing stops an old script from rewriting a newer store.
- Codex documents SessionStart context as `hookSpecificOutput.additionalContext` (plain stdout also works); `systemMessage` is a UI warning only. Hooks live in `.codex/hooks.json` or a `[[hooks.SessionStart]]` + `[[hooks.SessionStart.hooks]]` table pair, need `/hooks` trust, and model-visible output is capped near 2,500 tokens unless `additionalContextLimit` is raised. Relay emits `hookSpecificOutput.systemMessage` from a malformed TOML block, so Codex most likely never sees the handoff. (Source: https://learn.chatgpt.com/docs/hooks, fetched 2026-10-16.)
- Smaller confirmed bugs: provenance anchors to the wrong day's session number; `knowledge why` prints nothing once the source history is pruned; history pruning does nothing when the data path has a space; the documented save command breaks on any apostrophe.

### Decisions already made (do not reopen)

- Lesson fix = make reinforcement possible (ids in load, re-assert guidance, sharper lesson definition). **No** near-match blocking gate.
- Load format = ids on every entry, full bodies for the top-ranked entries within the existing word budgets, the rest listed by id.
- In scope: the small bugs above and the Codex hook fix. Out of scope: cross-machine sync, rolling the new version out to the 9 repos (see "After this plan").

## Global Constraints

- Bash 3.2 compatible: no `mapfile`, no associative arrays, no `${var,,}`; arrays use the existing `${arr[@]+"${arr[@]}"}` idiom under `set -u`.
- No new runtime dependencies in `relay.sh`. The installer may use jq or python3 only behind the existing `command -v` fallback pattern.
- After editing `relay.sh`, `install.sh`, anything in `adapters/`, or `tests/smoke-compact.sh`: run `bash bundle.sh` and commit `dist/install.sh` in the same commit. CI fails otherwise.
- Before every commit: `bash tests/run.sh && bash tests/smoke-compact.sh` must be fully green.
- No new `knowledge` subcommands (curation freeze; see Task 8).
- New prose and new output strings: no em dashes. Existing strings that tests match stay as they are.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Branch: `feature/knowledge-hardening`, cut from `main` after `docs/sync-design-docs` merges. If it has not merged, cut from `docs/sync-design-docs` so the Task 8 HTML edits don't conflict.

## Review Focus

1. A body passed both on stdin (`-`) and as a positional argument: expect a clean "one body argument" error, nothing written. (Test in Task 1.)
2. Stores with no `.relay-format` stamp (every existing install today): expect them to keep working and get stamped on the first write, never refused. (Test in Task 2.)
3. A fact restated with only whitespace differences: expect a plain confirmation with no new tombstone file. (Test in Task 3.)
4. A knowledge body containing a tab: expect load to render it on one line without shifting columns or dropping the id. (Test in Task 4.)
5. Codex started from a subdirectory of a repo whose path contains a space: expect the hook to resolve the repo root and still emit the handoff. (Test in Task 7.)

---

### Task 1: Reject unknown flags and split bodies in `knowledge add`; accept the body on stdin

**Files:**
- Modify: `relay.sh` (`k_add` argument loop, ~lines 531-563; `_is_empty_body`, line 688; the empty sweep reason in `k_compact`, line 738)
- Create: `tests/test_42_knowledge_add_args.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: `knowledge add ... -` reads the body from stdin (used by the skills in Task 5). `knowledge add` exits 2 on an unknown flag or on more than one positional argument. `_is_empty_body <file>` is true for an empty body or a flag-only body such as `--body`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_42_knowledge_add_args.sh`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_42_knowledge_add_args.sh`
Expected: `FAIL: expected [2], got [0]` on the first assert (today `--body` is accepted).

- [ ] **Step 3: Implement**

In `k_add`, replace the catch-all case of the option loop:

```bash
      *)        rest+=("$1");  shift;;
```

with:

```bash
      -)        rest+=("$(cat)"); shift;;          # body on stdin: no shell quoting to get wrong
      --*)      case "$1" in
                  *[[:space:]]*) rest+=("$1"); shift;;   # a body that starts with --, not a flag
                  *) echo "relay: unknown option for knowledge add: $1 (the body is one quoted argument, or - for stdin)" >&2; return 2;;
                esac;;
      *)        rest+=("$1");  shift;;
```

Directly after the existing `set -- ${rest[@]+"${rest[@]}"}` line in `k_add`, add:

```bash
  [ $# -le 1 ] || { echo "relay: knowledge add takes one body argument; quote the whole body or pass - and use stdin (got $#)" >&2; return 2; }
```

Replace `_is_empty_body`:

```bash
_is_empty_body() { # no content, or only a stray flag token such as "--body" (an old add stored the flag as the body)
  local b; b="$(_body "$1" | tr -d '[:space:]')"
  [ -z "$b" ] && return 0
  printf '%s' "$b" | grep -qE '^--[a-z][a-z-]*$'
}
```

In `k_compact` step 1, change the reason argument `"empty body"` to `"empty or flag-only body"`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_42_knowledge_add_args.sh && bash tests/run.sh && bash tests/smoke-compact.sh`
Expected: `PASS: knowledge add: ...`, `41/41 test files passed`, `SMOKE OK`. If smoke-compact asserts the literal text "empty body", update that assert to "empty or flag-only body".

- [ ] **Step 5: Rebundle and commit**

```bash
bash bundle.sh
git add relay.sh tests/test_42_knowledge_add_args.sh dist/install.sh tests/smoke-compact.sh
git commit -m "fix(relay): knowledge add rejects unknown flags and split bodies; '-' reads stdin

An agent passing --body/--text stored the flag as the body; 11 entries were lost
across installs. compact now sweeps flag-only bodies.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Format version guard on the data directory

**Files:**
- Modify: `relay.sh` (constants block at the top; `_lock`, lines 88-107; `cmd_load`, line 218 onward)
- Create: `tests/test_43_format_guard.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: `RELAY_FORMAT=2`; `_format_have` prints the stamped format (0 if missing or garbage); `_lock` returns 1, holding no lock, when the store is newer than this script; every successful `_lock` stamps `$DATA/.relay-format`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_43_format_guard.sh`:

```bash
#!/usr/bin/env bash
# test_43_format_guard.sh: an older relay.sh never writes a store laid out by a newer one.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

# an unstamped store (every install before this change) is stamped on first write, not refused
printf '## Summary\nfirst\n' | "$RELAY" save --dir "$DIR" --digest d
assert_eq "$(cat "$DIR/.relay-format")" "2"

# a store from a newer Relay: writes refused, nothing changed, no lock left behind
echo 99 > "$DIR/.relay-format"
before="$(cat "$DIR/latest.md")"
rc=0; err="$(printf 'second\n' | "$RELAY" save --dir "$DIR" --digest d2 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "1"; assert_contains "$err" "format 99"; assert_contains "$err" "install.sh --detect"
assert_eq "$(cat "$DIR/latest.md")" "$before"
[ ! -d "$DIR/.lock" ] || { echo "FAIL: lock left behind"; exit 1; }
rc=0; "$RELAY" knowledge add --fact --id f "x y z" --dir "$DIR" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1"
[ ! -e "$DIR/knowledge/facts/f.md" ] || { echo "FAIL: knowledge written into a newer store"; exit 1; }

# load is read-only: still works, and warns
out="$("$RELAY" load --dir "$DIR")"
assert_contains "$out" "newer Relay"; assert_contains "$out" "first"

# a garbage stamp counts as unstamped and is rewritten
echo junk > "$DIR/.relay-format"
printf 'third\n' | "$RELAY" save --dir "$DIR" --digest d3
assert_eq "$(cat "$DIR/.relay-format")" "2"
pass "format guard: stamp on write, refuse newer stores, load warns"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_43_format_guard.sh`
Expected: FAIL on the first `assert_eq` (`.relay-format` doesn't exist; `cat` errors).

- [ ] **Step 3: Implement**

Below `RELAY_LESSONS_MAX=...` at the top of `relay.sh`, add:

```bash
RELAY_FORMAT=2   # on-disk layout of .session-log/ (2 = table indexes). Bump on any change an older relay.sh would mangle.
```

After `_unlock()`, add:

```bash
_format_have() { local v; v="$(cat "$DATA/.relay-format" 2>/dev/null || true)"; case "$v" in ''|*[!0-9]*) v=0;; esac; printf '%s' "$v"; }

_format_ok() { # refuse a store written by a newer Relay; stamp an older or unstamped one
  local have; have="$(_format_have)"
  if [ "$have" -gt "$RELAY_FORMAT" ]; then
    echo "relay: $DATA uses format $have but this relay.sh writes format $RELAY_FORMAT; update this repo's Relay with: install.sh --detect" >&2
    return 1
  fi
  [ "$have" = "$RELAY_FORMAT" ] || printf '%s\n' "$RELAY_FORMAT" > "$DATA/.relay-format"
}
```

At the end of `_lock`, after `trap _unlock EXIT`, add:

```bash
  _format_ok || { _unlock; return 1; }
```

In `cmd_load`, directly after the `if/elif/else` block that sets the "Last saved" line in `out`, add:

```bash
  if [ "$(_format_have)" -gt "$RELAY_FORMAT" ]; then
    out="⚠ This .session-log was written by a newer Relay (format $(_format_have)); update .relay/ with install.sh --detect before saving."$'\n\n'"$out"
  fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_43_format_guard.sh && bash tests/run.sh && bash tests/smoke-compact.sh`
Expected: PASS, `42/42 test files passed`, `SMOKE OK`.

- [ ] **Step 5: Rebundle and commit**

```bash
bash bundle.sh
git add relay.sh tests/test_43_format_guard.sh dist/install.sh
git commit -m "feat(relay): stamp .session-log format; refuse writes to a newer store

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: A restated fact takes the newest wording

**Files:**
- Modify: `relay.sh` (`_k_add_fact`, lines 369-387; add `_squash` next to `_slugify`)
- Create: `tests/test_44_fact_restatement.sh`

**Interfaces:**
- Consumes: `_uniq_dest`, `_set_body`, `_similar` (existing).
- Produces: on a similar but differently worded re-add, the fact body becomes the new wording, the previous file is copied to `facts/superseded/<id>.prev.md` (made unique by `_uniq_dest`), and the output includes `updated wording: <id>` followed by the existing `confirmed: <id> (confirmed:N)` line.

- [ ] **Step 1: Write the failing test**

Create `tests/test_44_fact_restatement.sh`:

```bash
#!/usr/bin/env bash
# test_44_fact_restatement.sh: a similar-but-different restatement updates the fact (newest
# wording wins, previous kept as a tombstone) instead of silently keeping the old body.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
F="$DIR/knowledge/facts"
body() { awk 'BEGIN{d=0} /^---$/{d++; next} d>=2' "$1"; }

"$RELAY" knowledge add --fact --id deploy "Deploy with scripts/release.sh on the main branch; never npm publish" --dir "$DIR" >/dev/null
out="$("$RELAY" knowledge add --fact --id deploy "Deploy with scripts/deploy.sh on the main branch; never scripts/release.sh or npm publish" --dir "$DIR")"
assert_contains "$out" "updated wording: deploy"
assert_contains "$out" "confirmed: deploy (confirmed:2)"
assert_contains "$(body "$F/deploy.md")" "scripts/deploy.sh on the main branch"
assert_file "$F/superseded/deploy.prev.md"
assert_contains "$(cat "$F/superseded/deploy.prev.md")" "Deploy with scripts/release.sh on the main branch"

# whitespace-only restatement: plain confirm, no new tombstone
out="$("$RELAY" knowledge add --fact --id deploy "Deploy with scripts/deploy.sh on the main branch;   never scripts/release.sh or npm publish" --dir "$DIR")"
[ -z "$(printf '%s' "$out" | grep -F 'updated wording' || true)" ] || { echo "FAIL: whitespace change treated as new wording"; exit 1; }
assert_eq "$(ls "$F/superseded" | wc -l | tr -d ' ')" "1"
assert_contains "$out" "confirmed: deploy (confirmed:3)"

# a dissimilar body still raises a conflict and changes nothing
out="$("$RELAY" knowledge add --fact --id deploy "Auth lives in src/auth/session.ts and uses JWT." --dir "$DIR")"
assert_contains "$out" "conflict raised for fact: deploy"
assert_contains "$(body "$F/deploy.md")" "scripts/deploy.sh"
pass "fact restatement: newest wording wins with tombstone; whitespace confirms; divergent conflicts"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_44_fact_restatement.sh`
Expected: `FAIL: [confirmed: deploy (confirmed:2)] missing [updated wording: deploy]`.

- [ ] **Step 3: Implement**

After `_slugify`, add:

```bash
_squash() { printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }
```

In `_k_add_fact`, replace the similar branch:

```bash
    if _similar "$(_body "$f")" "$body"; then
      local c; c="$(_fm "$f" confirmed)"; c=$(( ${c:-1} + 1 ))
      _fm_set "$f" confirmed "$c"; _fm_set "$f" last_confirmed "$today"
      [ "$ttl" != none ] && _fm_set "$f" ttl "$ttl"    # refresh freshness window if the agent re-set it
      echo "confirmed: $id (confirmed:$c)"
```

with:

```bash
    if _similar "$(_body "$f")" "$body"; then
      local c; c="$(_fm "$f" confirmed)"; c=$(( ${c:-1} + 1 ))
      if [ "$(_squash "$(_body "$f")")" != "$(_squash "$body")" ]; then
        # a restatement is the agent's current understanding: newest wording wins, old kept for recovery
        local prev; mkdir -p "$DATA/knowledge/facts/superseded"
        prev="$(_uniq_dest "$DATA/knowledge/facts/superseded/$id.prev.md")"
        cp "$f" "$prev"
        _set_body "$f" "$body"
        echo "updated wording: $id (previous kept in facts/superseded/$(basename "$prev"))"
      fi
      _fm_set "$f" confirmed "$c"; _fm_set "$f" last_confirmed "$today"
      [ "$ttl" != none ] && _fm_set "$f" ttl "$ttl"    # refresh freshness window if the agent re-set it
      echo "confirmed: $id (confirmed:$c)"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_44_fact_restatement.sh && bash tests/run.sh && bash tests/smoke-compact.sh`
Expected: PASS, `43/43 test files passed`, `SMOKE OK`. `tests/test_12_knowledge_fact.sh` should still pass unchanged (its rephrase now also prints "updated wording", and its asserts still hold).

- [ ] **Step 5: Rebundle and commit**

```bash
bash bundle.sh
git add relay.sh tests/test_44_fact_restatement.sh dist/install.sh
git commit -m "fix(relay): a restated fact takes the newest wording instead of keeping the old body

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Load shows ids, full text up to the budget, and the rest by id

**Files:**
- Modify: `relay.sh` (`_load_knowledge`, lines 141-205; add `_kblock` above it)
- Modify: `tests/test_19_knowledge_load.sh` (the `"not loaded"` assert)
- Create: `tests/test_45_load_index.sh`

**Interfaces:**
- Consumes: `relay knowledge why <id>` (existing) as the way to open a listed entry.
- Produces: load lines shaped `` - `<id>`: <body> (confirmed:N) `` for facts and `` - `<id>`: <body> (seen:N, sessions:M) `` for lessons; a final `More (K, by id; open with: relay knowledge why <id>): id1, id2` line per section when over budget; a lessons hint line telling the agent to re-assert by id. Task 5's skills rely on the ids being visible.

- [ ] **Step 1: Write the failing test**

Create `tests/test_45_load_index.sh`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_45_load_index.sh`
Expected: FAIL on the first `small-fact` assert (load prints `- one two (confirmed:2)` without the id).

- [ ] **Step 3: Implement**

Add above `_load_knowledge`:

```bash
_kblock() { # word cap; ranked "...<TAB>id<TAB>line" rows on stdin -> full lines in rank order until the cap, then one id-only line
  awk -F'\t' -v cap="$1" '
    { id = $(NF - 1); line = $NF; n = split(line, w, " ")
      if (!full && (words + n <= cap || shown == 0)) { words += n; shown++; print line; next }
      full = 1; more++; rest = rest (more > 1 ? ", " : "") id }
    END { if (more) printf "More (%d, by id; open with: relay knowledge why <id>): %s\n", more, rest }'
}
```

In `_load_knowledge`, add `seen` to the first `local` line:

```bash
  local kd="$DATA/knowledge" f id body conf last ttl age seen
```

Replace the facts section (from `# ---- FACTS` through its `rm -f "$tmp"`) with:

```bash
  # ---- FACTS: rank by confirmed, then recency; every entry named by id ----
  tmp="$(mktemp)"
  for f in "$kd"/facts/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"; conf="$(_fm "$f" confirmed)"; last="$(_fm "$f" last_confirmed)"; ttl="$(_fm "$f" ttl)"
    body="$(_body "$f" | tr '\n\t' '  ')"
    age="$(_days_since "$last")"
    local lim; lim="$(_ttl_limit "$ttl")"
    [ "$age" -gt "$lim" ] && exp=$(( exp + 1 ))
    [ -f "$kd/facts/$id.conflict" ] && conflicts=$(( conflicts + 1 ))
    printf '%03d\t%09d\t%s\t- `%s`: %s (confirmed:%s)\n' \
      "${conf:-1}" "$(( 999999 - age ))" "$id" "$id" "$body" "${conf:-1}" >> "$tmp"
  done
  if [ -s "$tmp" ]; then
    total="$(grep -c . "$tmp" || true)"
    block="$(sort -t$'\t' -k1,1nr -k2,2nr "$tmp" | _kblock "$RELAY_FACTS_CAP")"
    shown="$(printf '%s\n' "$block" | grep -c '^- ' || true)"
    out="${out}## What this repo knows — facts"$'\n'
    [ "$shown" -lt "$total" ] && out="${out}⚠ $shown of $total facts shown in full; the rest are listed by id at the end of this section"$'\n'
    out="${out}${block}"$'\n'
    [ "$exp" -gt 0 ] && out="${out}($exp fact(s) past freshness window — run: relay knowledge prune)"$'\n'
    [ "$conflicts" -gt 0 ] && out="${out}(⚠ $conflicts fact conflict(s) pending — run: relay knowledge resolve <id>)"$'\n'
    [ "$total" -gt "$RELAY_FACTS_MAX" ] && out="${out}(⚠ $total facts over cap $RELAY_FACTS_MAX — run: relay knowledge compact)"$'\n'
  fi
  rm -f "$tmp"
```

Replace the lessons section (from `# ---- LESSONS` through its `rm -f "$tmp"`) with:

```bash
  # ---- LESSONS (active): rank by seen, then recency; every entry named by id ----
  tmp="$(mktemp)"
  for f in "$kd"/lessons/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"; seen="$(_fm "$f" seen)"; seen="${seen:-1}"
    body="$(_body "$f" | tr '\n\t' '  ')"
    age="$(_days_since "$(_fm "$f" last_seen)")"
    printf '%05d\t%09d\t%s\t- `%s`: %s (seen:%s, sessions:%s)\n' \
      "$seen" "$(( 999999 - age ))" "$id" "$id" "$body" "$seen" "$(_fm "$f" sessions)" >> "$tmp"
  done
  if [ -s "$tmp" ]; then
    total="$(grep -c . "$tmp" || true)"
    block="$(sort -t$'\t' -k1,1nr -k2,2nr "$tmp" | _kblock "$RELAY_LESSONS_CAP")"
    shown="$(printf '%s\n' "$block" | grep -c '^- ' || true)"
    out="${out}## What this repo knows — lessons"$'\n'
    out="${out}(If one of these applied again this session, re-assert it by id when saving: knowledge add --lesson --id <id> ...)"$'\n'
    [ "$shown" -lt "$total" ] && out="${out}⚠ $shown of $total lessons shown in full; the rest are listed by id at the end of this section"$'\n'
    out="${out}${block}"$'\n'
    [ "$total" -gt "$RELAY_LESSONS_MAX" ] && out="${out}(⚠ $total lessons over cap $RELAY_LESSONS_MAX — run: relay knowledge compact)"$'\n'
  fi
  rm -f "$tmp"
```

In `tests/test_19_knowledge_load.sh`, change:

```bash
assert_contains "$out" "not loaded"
```

to:

```bash
assert_contains "$out" "listed by id"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_45_load_index.sh && bash tests/run.sh && bash tests/smoke-compact.sh`
Expected: PASS, `44/44 test files passed`, `SMOKE OK`.

- [ ] **Step 5: Check the real-world output size**

Run: `cd ../product-almanac && ~/Documents/GitHub/relay/relay.sh load --dir .session-log | wc -w; cd -`
Expected: under about 2,200 words, with every one of the 50 facts and 47 lessons named either in full or in a `More` line. Record the number in the commit message body.

- [ ] **Step 6: Rebundle and commit**

```bash
bash bundle.sh
git add relay.sh tests/test_45_load_index.sh tests/test_19_knowledge_load.sh dist/install.sh
git commit -m "feat(relay): load names every knowledge entry by id; overflow listed, not dropped

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Skills reinforce lessons by id, define a lesson sharply, and pass bodies on stdin

**Files:**
- Modify: `adapters/skills/session-save/SKILL.md`, `adapters/skills/relay-learn/SKILL.md`, `adapters/skills/relay-compact/SKILL.md`
- Modify: `adapters/codex/skills/session-save/SKILL.md`, `adapters/codex/skills/relay-learn/SKILL.md`, `adapters/codex/skills/relay-compact/SKILL.md`
- Modify: `adapters/opencode/commands/session-save.md`, `adapters/opencode/commands/relay-learn.md`, `adapters/opencode/commands/relay-compact.md`
- Create: `tests/test_46_skill_guidance.sh`

**Interfaces:**
- Consumes: `knowledge add ... -` (Task 1), ids in the load output (Task 4).
- Produces: nothing used by later tasks.

- [ ] **Step 1: Write the failing test**

Create `tests/test_46_skill_guidance.sh`:

```bash
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
pass "skills: stdin bodies, lesson re-assertion by id, sharp lesson definition"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_46_skill_guidance.sh`
Expected: `FAIL: [...] missing [<<'RELAY_HANDOFF'] ...`

- [ ] **Step 3: Rewrite the shared Claude Code / Cursor / Grok skills**

Replace the whole of `adapters/skills/session-save/SKILL.md` with:

~~~~markdown
---
name: session-save
description: Save a Relay handoff so the next session can pick up where you left off
---

Persist a Relay handoff for the next agent.

1. Author the six sections as concise markdown (`## Summary`, `## Changed`,
   `## Decisions`, `## Next`, `## Watch out`, `## Open questions`), naming real
   files/paths and dated facts. Carry forward every still-open item from the
   loaded handoff's `## Next` and `## Open questions`: this handoff replaces it.
   Compose a one-line digest with no single quotes in it.
2. Persist it. The script owns all file writes, rotation, and locking. The
   quoted heredoc passes the markdown through untouched, apostrophes included.
   Keep the closing `RELAY_HANDOFF` at the start of its line:

```bash
"$PWD/.relay/relay.sh" save --dir "$PWD/.session-log" \
  --digest '<<one-line digest>>' <<'RELAY_HANDOFF'
<<the six sections as markdown>>
RELAY_HANDOFF
```

3. Reply: "Handoff saved for the next session."
4. Reinforce lessons. Session start listed each lesson with its id. For each
   loaded lesson that actually applied again in this session, re-assert it
   under the SAME id (sharpen the wording if you learned more):

```bash
"$PWD/.relay/relay.sh" knowledge add --lesson --id <existing-id> - \
  --dir "$PWD/.session-log" <<'RELAY_BODY'
<<lesson text>>
RELAY_BODY
```

   Re-asserting on a new day is what moves a lesson toward graduation. Do not
   re-assert a lesson only because it was loaded.
5. Capture new durable knowledge from this session (skip if none) with the
   `relay-learn` skill. If the tool says a lesson is graduation-ready, offer
   graduation in one line. Never graduate without the user's okay.
6. If `knowledge list` reports counts over cap (or a load warned
   "(⚠ N ... over cap ...)"), offer `relay-compact` in one line.
   Never run it unasked.

Do not write `.session-log/relay-instructions.md`. Session start reads
`.session-log/latest.md` and `.session-log/index.md` only.
~~~~

Replace the whole of `adapters/skills/relay-learn/SKILL.md` with:

~~~~markdown
---
name: relay-learn
description: Record a durable fact or lesson about this repo into Relay knowledge
---

Capture a single durable piece of knowledge about THIS repo for future sessions.

1. Decide the kind:
   - **Fact**: a durable truth about the repo (a command, a path, a gotcha, a
     specific value or count, how one incident was resolved).
   - **Lesson**: a reusable rule for future, different tasks, phrased "when X,
     prefer Y, because Z". If it only makes sense for the task you just did,
     it is a fact, not a lesson.
2. Look for an existing entry first so you reuse its id instead of duplicating.
   Use `--fact` or `--lesson` to match the kind:

```bash
"$PWD/.relay/relay.sh" knowledge add --lesson --near 'a few key words' \
  --dir "$PWD/.session-log"
```

3. Write it (reuse a surfaced id, or coin a short stable kebab-case slug). Pass
   the body on stdin with `-` so quotes and apostrophes need no escaping, and
   keep the closing `RELAY_BODY` at the start of its line. Add `--ttl <days>`
   to a fact that is only true for a while; omit it for durable truths. The
   only options are `--fact`, `--lesson`, `--id`, `--ttl`, `--near` and
   `--dir`; anything else is rejected.

```bash
"$PWD/.relay/relay.sh" knowledge add --fact --id <slug> - \
  --dir "$PWD/.session-log" <<'RELAY_BODY'
<fact or lesson text>
RELAY_BODY
```

4. If the tool reports a lesson is graduation-ready, offer (one line) to run
   `knowledge graduate <slug>`. Never graduate without the user's okay.

Do not write `.session-log/relay-instructions.md`. Session start reads
`.session-log/latest.md` and `.session-log/index.md` only.
~~~~

In `adapters/skills/relay-compact/SKILL.md`, step 5, replace the line:

```
   - merge/rewrite: `R knowledge add --fact|--lesson --id <kept-slug> '<rewritten body>' D`
```

with:

~~~~
   - merge/rewrite (body on stdin; closing `RELAY_BODY` at the start of its line):

```bash
R knowledge add --fact|--lesson --id <kept-slug> - D <<'RELAY_BODY'
<rewritten body>
RELAY_BODY
```
~~~~

(Find the exact line with `grep -n "rewritten body" adapters/skills/relay-compact/SKILL.md` first; keep its leading indentation.)

- [ ] **Step 4: Rewrite the Codex skills**

Replace the whole of `adapters/codex/skills/session-save/SKILL.md` with:

~~~~markdown
<!-- adapters/codex/skills/session-save/SKILL.md -->
---
name: session-save
description: Save a Relay handoff for the next Codex session
---
Persist a Relay handoff for the next agent.

1. Author the six sections (`## Summary`, `## Changed`, `## Decisions`, `## Next`,
   `## Watch out`, `## Open questions`). Carry forward every still-open item from
   the loaded handoff's `## Next` and `## Open questions`: this handoff replaces it.
   Compose a one-line digest with no single quotes in it.
2. Run (keep the closing `RELAY_HANDOFF` at the start of its line):

```bash
"${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" save --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log" \
  --digest '<<one-line digest>>' <<'RELAY_HANDOFF'
<<six sections>>
RELAY_HANDOFF
```

3. Reply: "Handoff saved for the next session."
4. Reinforce lessons. Session start listed each lesson with its id. For each
   loaded lesson that actually applied again, re-assert it under the SAME id:

```bash
"${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --lesson --id <existing-id> - \
  --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log" <<'RELAY_BODY'
<<lesson text>>
RELAY_BODY
```

   Do not re-assert a lesson only because it was loaded.
5. Capture new durable knowledge with `$relay-learn` (skip if none). Offer
   graduation only when prompted and approved.
6. If `knowledge list` reports counts over cap (or the session-start load warned
   "(⚠ N ... over cap ...)"), offer `$relay-compact` in one line. Never run it unasked.
~~~~

Replace the whole of `adapters/codex/skills/relay-learn/SKILL.md` with:

~~~~markdown
<!-- adapters/codex/skills/relay-learn/SKILL.md -->
---
name: relay-learn
description: Record a durable fact or lesson about this repo into Relay knowledge
---
Capture one durable piece of knowledge about THIS repo for future sessions.

1. Fact = durable repo truth (a command, path, gotcha, specific value, how one
   incident was resolved). Lesson = reusable rule for future, different tasks
   ("when X, prefer Y, because Z"). If it only makes sense for the task you just
   did, it is a fact, not a lesson.
2. Check for a match first (reuse the id, don't duplicate); use `--fact` or `--lesson`:

```bash
"${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --lesson --near 'a few key words' \
  --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log"
```

3. Write it with a short stable kebab-case `--id`, body on stdin via `-` (closing
   `RELAY_BODY` at the start of its line). The only options are `--fact`,
   `--lesson`, `--id`, `--ttl`, `--near` and `--dir`; anything else is rejected.

```bash
"${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --fact --id <slug> - \
  --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log" <<'RELAY_BODY'
<fact or lesson text>
RELAY_BODY
```

4. If a lesson is graduation-ready, offer to `knowledge graduate <slug>`, only with the user's okay.
~~~~

In `adapters/codex/skills/relay-compact/SKILL.md`, replace the step 5 line containing `'<rewritten body>'` with the same stdin block as Step 3 above (`R knowledge add --fact|--lesson --id <kept-slug> - D <<'RELAY_BODY'` … `RELAY_BODY`), keeping that file's indentation.

- [ ] **Step 5: Rewrite the OpenCode commands**

Replace the whole of `adapters/opencode/commands/session-save.md` with:

~~~~markdown
<!-- adapters/opencode/commands/session-save.md -->
---
description: Save a Relay handoff so the next opencode session can pick up where you left off
---
Persist a Relay handoff for the next agent.

1. Author the six sections as concise markdown (`## Summary`, `## Changed`,
   `## Decisions`, `## Next`, `## Watch out`, `## Open questions`), naming real
   files/paths and dated facts. Carry forward every still-open item from the
   loaded handoff's `## Next` and `## Open questions`: this handoff replaces it.
   Compose a one-line digest with no single quotes in it.
2. Persist it (keep the closing `RELAY_HANDOFF` at the start of its line):

```bash
"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" save --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" \
  --digest '<<one-line digest>>' <<'RELAY_HANDOFF'
<<the six sections as markdown>>
RELAY_HANDOFF
```

3. Reply: "Handoff saved for the next session."
4. Reinforce lessons. Session start listed each lesson with its id. For each
   loaded lesson that actually applied again, re-assert it under the SAME id:

```bash
"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --lesson --id <existing-id> - \
  --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" <<'RELAY_BODY'
<<lesson text>>
RELAY_BODY
```

   Do not re-assert a lesson only because it was loaded.
5. Capture new durable knowledge with `/relay-learn` (skip if none). If the tool
   says a lesson is graduation-ready, offer graduation in one line.
6. Refresh the snapshot opencode auto-loads next session via `opencode.json`'s
   `instructions` field (run this after any knowledge writes too):

```bash
"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" load --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" \
  > "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log/relay-instructions.md"
```

7. If `knowledge list` reports counts over cap (or step 6's load warned
   "(⚠ N ... over cap ...)"), offer `/relay-compact` in one line. Never run it unasked.
~~~~

Replace the whole of `adapters/opencode/commands/relay-learn.md` with:

~~~~markdown
<!-- adapters/opencode/commands/relay-learn.md -->
---
description: Record a durable fact or lesson about this repo into Relay knowledge
---
Capture a single durable piece of knowledge about THIS repo for future sessions.

1. Decide the kind:
   - **Fact**: a durable truth about the repo (a command, a path, a gotcha, a
     specific value or count, how one incident was resolved).
   - **Lesson**: a reusable rule for future, different tasks, phrased "when X,
     prefer Y, because Z". If it only makes sense for the task you just did,
     it is a fact, not a lesson.
2. Look for an existing entry first so you reuse its id; use `--fact` or `--lesson`:

```bash
"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --lesson --near 'a few key words' \
  --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log"
```

3. Write it (reuse a surfaced id, or coin a short stable kebab-case slug), body on
   stdin via `-` (closing `RELAY_BODY` at the start of its line). Add `--ttl <days>`
   to a fact that is only true for a while. The only options are `--fact`,
   `--lesson`, `--id`, `--ttl`, `--near` and `--dir`; anything else is rejected.

```bash
"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --fact --id <slug> - \
  --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" <<'RELAY_BODY'
<fact or lesson text>
RELAY_BODY
```

4. Refresh the snapshot opencode auto-loads next session:

```bash
"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" load --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" \
  > "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log/relay-instructions.md"
```

5. If the tool reports a lesson is graduation-ready, offer (one line) to run
   `knowledge graduate <slug>`. Never graduate without the user's okay.
~~~~

In `adapters/opencode/commands/relay-compact.md`, replace the step 5 line containing `'<rewritten body>'` with the same stdin block as Step 3 above, keeping that file's indentation.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/test_46_skill_guidance.sh && bash tests/run.sh && bash tests/smoke-compact.sh`
Expected: PASS, `45/45 test files passed`, `SMOKE OK`. `test_07`, `test_08`, `test_35` still assert "relay.sh" and "relay-instructions.md"; both remain present.

- [ ] **Step 7: Prove the documented commands run as written**

Copy the session-save and relay-learn code blocks above into a scratch shell script, substituting a temp dir for `$PWD`, plus a handoff that contains `Jeremy's` and a lesson containing `don't`. Run it.
Expected: exit 0; `latest.md` contains `Jeremy's`; the lesson file contains `don't`.

- [ ] **Step 8: Rebundle and commit**

```bash
bash bundle.sh
git add adapters tests/test_46_skill_guidance.sh dist/install.sh
git commit -m "feat(adapters): re-assert loaded lessons by id; sharper lesson definition; stdin bodies

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Provenance, `why` on pruned sources, and pruning paths with spaces

**Files:**
- Modify: `relay.sh` (`_provenance`, lines 293-301; `_prune`, lines 109-116; `k_why`, lines 777-788)
- Create: `tests/test_47_small_fixes.sh`

**Interfaces:**
- Consumes: `_fm` (existing).
- Produces: nothing used by later tasks.

- [ ] **Step 1: Write the failing test**

Create `tests/test_47_small_fixes.sh`:

```bash
#!/usr/bin/env bash
# test_47_small_fixes.sh: provenance anchors only to today's session; why reports a pruned
# source; history pruning works when the data path contains a space.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
today="$(date +%F)"
yesterday="$(date -v-1d +%F 2>/dev/null || date -d yesterday +%F)"

# yesterday's latest.md must not lend its session number to today's history file
mkdir -p "$DIR/history"
printf -- '---\ndate: %s\nsession: 3\ndigest: "y"\n---\nbody\n' "$yesterday" > "$DIR/latest.md"
"$RELAY" knowledge add --lesson --id before-save "when A prefer B" --dir "$DIR" >/dev/null
assert_eq "$(sed -n 's/^source: //p' "$DIR/knowledge/lessons/before-save.md")" "history/$today.md"
printf '## Summary\nx\n' | "$RELAY" save --dir "$DIR" --digest d
"$RELAY" knowledge add --lesson --id after-save "when C prefer D" --dir "$DIR" >/dev/null
assert_eq "$(sed -n 's/^source: //p' "$DIR/knowledge/lessons/after-save.md")" "history/$today.md#session-1"

# why: a pruned source is named, not silently skipped
printf -- '---\nid: old\nkind: fact\nconfirmed: 1\nfirst_seen: 2020-01-01\nlast_confirmed: 2020-01-01\nttl: none\nsource: history/2020-01-01.md#session-1\nstatus: active\n---\nold fact body\n' \
  > "$DIR/knowledge/facts/old.md"
assert_contains "$("$RELAY" knowledge why old --dir "$DIR")" "no longer on disk"

# prune when the data dir path contains a space
SP="$(mktemp -d)/with space/.session-log"; mkdir -p "$SP/history"
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do printf 'x\n' > "$SP/history/2020-01-$i.md"; done
printf 'x\n' | "$RELAY" save --dir "$SP" --digest d
assert_eq "$(ls "$SP/history" | wc -l | tr -d ' ')" "10"
[ ! -e "$SP/history/2020-01-03.md" ] || { echo "FAIL: oldest history not pruned"; exit 1; }
assert_file "$SP/history/2020-01-04.md"
assert_file "$SP/history/$today.md"
pass "provenance anchors to today only; why names a pruned source; prune survives spaces"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_47_small_fixes.sh`
Expected: `FAIL: expected [history/<today>.md], got [history/<today>.md#session-3]`.

- [ ] **Step 3: Implement**

Replace `_provenance`:

```bash
_provenance() { # today's history file, anchored to today's last saved session when there is one
  local today src sess
  today="$(date +%F)"; src="history/$today.md"
  if [ -f "$DATA/latest.md" ] && [ "$(_fm "$DATA/latest.md" date)" = "$today" ]; then
    sess="$(_fm "$DATA/latest.md" session)"
    [ -n "$sess" ] && src="$src#session-$sess"
  fi
  printf '%s' "$src"
}
```

Replace `_prune`:

```bash
_prune() { # keep the newest RELAY_WINDOW history files; glob order is ascending by YYYY-MM-DD name
  local files i
  files=("$DATA/history"/*.md)
  [ -e "${files[0]}" ] || return 0
  for (( i = 0; i < ${#files[@]} - RELAY_WINDOW; i++ )); do rm -f "${files[$i]}"; done
  return 0
}
```

In `k_why`, replace the final `if` block:

```bash
  if [ -n "$hist" ] && [ -f "$DATA/$hist" ]; then
    echo; echo "--- came from $src ---"; sed -n '1,40p' "$DATA/$hist"
  fi
```

with:

```bash
  if [ -n "$hist" ] && [ -f "$DATA/$hist" ]; then
    echo; echo "--- came from $src ---"; sed -n '1,40p' "$DATA/$hist"
  elif [ -n "$hist" ]; then
    echo; echo "(source $src is no longer on disk: history keeps the last $RELAY_WINDOW session days)"
  fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_47_small_fixes.sh && bash tests/run.sh && bash tests/smoke-compact.sh`
Expected: PASS, `46/46 test files passed`, `SMOKE OK`. `tests/test_04_prune.sh` must still pass.

- [ ] **Step 5: Rebundle and commit**

```bash
bash bundle.sh
git add relay.sh tests/test_47_small_fixes.sh dist/install.sh
git commit -m "fix(relay): provenance anchors to today only; why names pruned sources; prune handles spaces

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Wire Codex to its documented hook contract

**Files:**
- Create: `adapters/codex/hooks.relay.json`
- Delete: `adapters/codex/hooks.relay.toml`
- Modify: `adapters/codex/relay-session-start.sh`
- Modify: `relay.sh` (`cmd_load` codex branch, lines 235-237)
- Modify: `install.sh` (`wire_codex`, lines 115-122; add `drop_legacy_codex_toml`; codex note in `main`)
- Modify: `tests/test_08_codex_adapter.sh`, `tests/test_19_knowledge_load.sh`, `tests/test_38_install_cli_picker.sh`
- Create: `tests/test_48_install_codex.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: `relay.sh load --format codex` prints `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"}}`. The installer writes or merges `.codex/hooks.json` and removes the old block from `.codex/config.toml`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_48_install_codex.sh`:

```bash
#!/usr/bin/env bash
# test_48_install_codex.sh: --clis codex wires .codex/hooks.json (Codex's documented hook file),
# removes the old config.toml block, merges with existing hooks, stays idempotent, and the hook
# emits SessionStart additionalContext from a subdirectory of a repo whose path has a space.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
SRC="$(cd .. && pwd)"; TMP="$(mktemp -d)/repo with space"; mkdir -p "$TMP"
( cd "$TMP" && git init -q && mkdir -p .codex sub )
printf 'model = "gpt-5"\n' > "$TMP/.codex/config.toml"
printf '# adapters/codex/hooks.relay.toml — merge into .codex/config.toml\n[[hooks.SessionStart]]\ncommand = [".relay/adapters/codex/relay-session-start.sh"]\n' \
  >> "$TMP/.codex/config.toml"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}\n' > "$TMP/.codex/hooks.json"

( cd "$TMP" && bash "$SRC/install.sh" --clis codex --from "$SRC" </dev/null >/dev/null )
( cd "$TMP" && bash "$SRC/install.sh" --clis codex --from "$SRC" </dev/null >/dev/null )   # idempotent

cfg="$(cat "$TMP/.codex/config.toml")"
assert_contains "$cfg" 'model = "gpt-5"'
[ -z "$(printf '%s' "$cfg" | grep -F 'hooks.SessionStart' || true)" ] || { echo "FAIL: legacy toml block left behind"; exit 1; }
hj="$(cat "$TMP/.codex/hooks.json")"
assert_contains "$hj" "echo mine"
assert_contains "$hj" "additionalContextLimit"
assert_eq "$(grep -o 'relay-session-start.sh' "$TMP/.codex/hooks.json" | wc -l | tr -d ' ')" "1"

printf '## Summary\nhello from codex hooks\n' | "$TMP/.relay/relay.sh" save --dir "$TMP/.session-log" --digest d
out="$(cd "$TMP/sub" && bash "$TMP/.relay/adapters/codex/relay-session-start.sh")"
assert_contains "$out" '"hookEventName":"SessionStart"'
assert_contains "$out" '"additionalContext"'
assert_contains "$out" 'hello from codex hooks'
[ -z "$(printf '%s' "$out" | grep -F 'systemMessage' || true)" ] || { echo "FAIL: still emits systemMessage"; exit 1; }
pass "codex install: hooks.json wired, legacy toml removed, merge + idempotent, additionalContext from subdir"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_48_install_codex.sh`
Expected: `FAIL: legacy toml block left behind`.

- [ ] **Step 3: Implement the adapter files**

Create `adapters/codex/hooks.relay.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|compact",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.relay/adapters/codex/relay-session-start.sh\"",
            "additionalContextLimit": 6000
          }
        ]
      }
    ]
  }
}
```

Delete the old file: `git rm adapters/codex/hooks.relay.toml`

Replace `adapters/codex/relay-session-start.sh` with:

```bash
#!/usr/bin/env bash
# Codex SessionStart hook → emits {hookSpecificOutput:{additionalContext:<handoff>}} JSON,
# which Codex adds to the model's developer context. Codex sets no project-dir variable,
# so resolve the repo root from git (the hook may run from a subdirectory).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -x "$ROOT/.relay/relay.sh" ] || exit 0
"$ROOT/.relay/relay.sh" load --dir "$ROOT/.session-log" --format codex 2>/dev/null || true
exit 0
```

In `relay.sh` `cmd_load`, replace:

```bash
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","systemMessage":"%s"}}\n' \
```

with:

```bash
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
```

- [ ] **Step 4: Implement the installer**

In `install.sh`, add above `wire_codex`:

```bash
drop_legacy_codex_toml() { # older installs appended a [[hooks.SessionStart]] block Codex never ran
  local cfg=".codex/config.toml"
  [ -f "$cfg" ] && grep -qF "# adapters/codex/hooks.relay.toml" "$cfg" || return 0
  awk '
    index($0, "# adapters/codex/hooks.relay.toml") == 1 { skip = 2; next }
    skip == 2 && $0 == "[[hooks.SessionStart]]" { skip = 1; next }
    skip == 1 && index($0, "relay-session-start.sh") { skip = 0; next }
    { skip = 0; print }' "$cfg" > "$cfg.relaytmp" && mv "$cfg.relaytmp" "$cfg"
  grep -q '[^[:space:]]' "$cfg" || rm -f "$cfg"
}
```

Replace `wire_codex` with:

```bash
wire_codex() {
  mkdir -p .codex/skills
  [ -d .relay/adapters/codex/skills ] && cp -R .relay/adapters/codex/skills/* .codex/skills/ 2>/dev/null || true
  append_block AGENTS.md .relay/adapters/codex/AGENTS.relay.md
  drop_legacy_codex_toml
  local hj=".codex/hooks.json" src=".relay/adapters/codex/hooks.relay.json"
  if [ ! -f "$hj" ]; then cp "$src" "$hj"; return 0; fi
  grep -qF "relay-session-start.sh" "$hj" && return 0    # idempotent
  if command -v jq >/dev/null 2>&1; then
    jq --slurpfile r "$src" '.hooks.SessionStart = ((.hooks.SessionStart // []) + $r[0].hooks.SessionStart)' \
      "$hj" > "$hj.tmp" && mv "$hj.tmp" "$hj"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$hj" "$src" <<'PY'
import json, sys
p, src = sys.argv[1], sys.argv[2]
d = json.load(open(p)); r = json.load(open(src))
d.setdefault("hooks", {}).setdefault("SessionStart", []).extend(r["hooks"]["SessionStart"])
json.dump(d, open(p, "w"), indent=2)
PY
  else
    echo "relay: cannot auto-merge $hj; add the SessionStart entry from $src by hand" >&2
  fi
}
```

In `install.sh` `main`, after the existing Grok note line, add:

```bash
  case " $selected " in *" codex "*) echo "relay: in Codex, run /hooks once to review and trust the Relay SessionStart hook.";; esac
```

- [ ] **Step 5: Update the existing tests**

In `tests/test_08_codex_adapter.sh`, change `assert_contains "$out" '"systemMessage"'` to `assert_contains "$out" '"additionalContext"'`, and change the line asserting on `hooks.relay.toml` to:

```bash
assert_contains "$(cat "$SRC/adapters/codex/hooks.relay.json")" "SessionStart"
```

In `tests/test_19_knowledge_load.sh`, change `assert_contains "$out" '"systemMessage"'` (the codex block) to `assert_contains "$out" '"additionalContext"'`.

In `tests/test_38_install_cli_picker.sh`, change `assert_file "$TMP/.codex/config.toml"` to `assert_file "$TMP/.codex/hooks.json"`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/test_48_install_codex.sh && bash tests/run.sh && bash tests/smoke-compact.sh`
Expected: PASS, `47/47 test files passed`, `SMOKE OK`.

- [ ] **Step 7: Verify against a real Codex (codex-cli 0.163.0 is installed)**

```bash
cd "$(mktemp -d)" && git init -q
bash ~/Documents/GitHub/relay/install.sh --clis codex </dev/null
printf '## Summary\nRELAY-CANARY-7731\n' | .relay/relay.sh save --dir .session-log --digest canary
codex
```

In Codex: trust the project if prompted, run `/hooks`, review and trust the Relay SessionStart hook, quit, start `codex` again in the same directory, and ask: "Quote the Relay handoff summary line from your context, verbatim."
Expected: `RELAY-CANARY-7731`. If it is absent, stop: record exactly what `/hooks` shows and what Codex answers, and do not merge this task.

- [ ] **Step 8: Rebundle and commit**

```bash
bash bundle.sh
git add adapters/codex relay.sh install.sh tests/test_08_codex_adapter.sh tests/test_19_knowledge_load.sh \
  tests/test_38_install_cli_picker.sh tests/test_48_install_codex.sh dist/install.sh
git commit -m "fix(codex): wire .codex/hooks.json and emit additionalContext so Codex loads the handoff

Codex documents SessionStart context as hookSpecificOutput.additionalContext;
systemMessage is a UI warning. The old config.toml block was malformed and is removed.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Sync the docs and record the curation freeze

**Files:**
- Modify: `README.md`, `docs/design-spec.md`, `docs/relay-learning-design.html`

**Interfaces:**
- Consumes: the behavior shipped in Tasks 1-7.
- Produces: docs that match the code.

- [ ] **Step 1: README.md**

1. In **Use**, replace the **Load** bullet with:
   "**Load** is automatic: the last handoff, active knowledge, and the index are injected at session start. Every knowledge entry is named by its id. The top-ranked entries appear in full under their own word budget, and the rest are listed by id (`relay knowledge why <id>` opens one), so nothing is silently dropped."
2. In **Knowledge model**, append to the **Facts** bullet:
   "Restating a fact in similar words updates it to the newest wording and keeps the previous version in `facts/superseded/`."
3. In **Command surface**, add under the existing `add` lines:
   `relay knowledge add --fact --id <slug> - <<'EOF'      # body on stdin (quote-safe)`
   and below the block: "`knowledge add` rejects unknown options and more than one body argument."
4. In the CLI table, replace the Codex row with:
   `| Codex | `SessionStart` hook in `.codex/hooks.json` (run `/hooks` once to trust it) + `AGENTS.md` fallback | `.codex/skills/` → `$session-save`, `$relay-learn`, `$relay-compact` |`
5. In **Update**, append:
   "From this version on, `.session-log/.relay-format` records the data layout. A `relay.sh` older than the data refuses to write and tells you to update, instead of mangling the files."
6. In **Layout**, add under `.session-log/`: `  .relay-format      data layout version (an older relay.sh refuses to write)`.

- [ ] **Step 2: docs/design-spec.md**

1. Line 208: replace "Codex `hookSpecificOutput.systemMessage` JSON object (`--format codex`)" with "Codex `hookSpecificOutput.additionalContext` JSON object (`--format codex`)".
2. Line 231 (Codex row): replace "`SessionStart` hook in `.codex/config.toml` runs `relay load --format codex` (`systemMessage`)" with "`SessionStart` hook in `.codex/hooks.json` runs `relay load --format codex` (`additionalContext`, limit raised to 6000; trusted once via `/hooks`)".
3. End of §5: add a paragraph describing `.relay-format` (value 2, stamped on every locked write, newer value means writes are refused and load warns).
4. End of §13: add "Unknown `knowledge add` options and multiple body arguments exit 2 and write nothing. A store with a newer `.relay-format` makes every locked write exit 1."
5. §17 Future: add "**Curation freeze.** No new knowledge subcommands until re-assertion is visible in real stores: at least one lesson in some install reaching `sessions: 2` via re-assertion of a loaded id. Check by listing `sessions:` across installs."

- [ ] **Step 3: docs/relay-learning-design.html**

1. Line 314: `SessionStart hook → systemMessage` becomes `SessionStart hook → additionalContext` (Codex node only; line 317's Grok node stays `systemMessage`).
2. Line 429, facts cell: replace "Same id + similar body (word-overlap ≥ 50%) confirms; divergent body writes a <code>.conflict</code> sidecar, never an overwrite" with "Same id + similar body (word-overlap ≥ 50%) confirms and takes the newest wording (previous kept in <code>superseded/</code>); divergent body writes a <code>.conflict</code> sidecar".
3. Line 433: facts cell becomes "Named by id, ranked by <code>confirmed</code> then recency; full text up to a 400-word budget, the rest listed by id". Lessons cell becomes "Active only, named by id, ranked by <code>seen</code> then recency, same budget rule. Graduated ones load via <code>AGENTS.md</code> instead".
4. Line 480: replace "Codex <code>hookSpecificOutput.systemMessage</code> JSON" with "Codex <code>hookSpecificOutput.additionalContext</code> JSON".

Confirm each edit lands with `grep -n "additionalContext\|newest wording\|listed by id" docs/relay-learning-design.html`.

- [ ] **Step 4: Final verification**

```bash
bash bundle.sh && git diff --exit-code dist/install.sh
bash tests/run.sh && bash tests/smoke-compact.sh
```

Expected: no diff, `47/47 test files passed`, `SMOKE OK`.

- [ ] **Step 5: Commit, push, open the PR**

```bash
git add README.md docs/design-spec.md docs/relay-learning-design.html
git commit -m "docs(relay): sync README, spec, and walkthrough to knowledge hardening; record curation freeze

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin feature/knowledge-hardening
gh pr create --title "Knowledge hardening: no lost bodies, ids in load, Codex hook fix" --body "$(cat <<'EOF'
Fixes the issues measured in the 2026-10-16 review: flag-shaped bodies lost on write,
knowledge past the budget invisible, lessons never reinforced (no ids in load),
corrected facts keeping the old body, no format guard, Codex never loading the handoff,
and three small bugs. Plan: docs/superpowers/plans/2026-10-16-knowledge-hardening.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: CI green on Ubuntu and macOS.

---

## After this plan (not tasks here)

- Roll out: in each of the 9 repos, `bash ~/Documents/GitHub/relay/install.sh --detect`, commit `.relay/`, and in Codex repos run `/hooks` once.
- Clean up: run `relay knowledge compact` (dry run, then `--yes`) in product-almanac and product-forge to sweep the 11 flag-only entries. Their original text is gone; check those days' history files if any of it is worth re-recording.
- Re-measure in about 3 weeks: count lessons with `sessions >= 2` across installs. If it's still zero, the reinforcement design needs rethinking before any new knowledge features.
