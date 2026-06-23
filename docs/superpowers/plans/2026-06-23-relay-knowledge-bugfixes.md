# Relay Knowledge Bug Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the four correctness bugs found in the PR #2 knowledge command code in `relay.sh`, with regression tests, and regenerate the `dist/install.sh` bundle.

**Architecture:** All four bugs live in `relay.sh` (a single bash script run under `set -euo pipefail` on macOS/BSD). Fixes are surgical edits to that one file plus new test files under `tests/`. After the source is fixed, `./bundle.sh` regenerates `dist/install.sh` (a byte-for-byte embedded copy), and the full suite must stay green.

**Tech Stack:** Bash, BSD/GNU awk/sed/date, zero-dependency test harness (`tests/helper.sh`).

## Global Constraints

- Script runs under `set -euo pipefail`; never introduce a bare `var=$(cmd)` whose `cmd` can return non-zero on a normal path.
- macOS default is **BSD awk** — never pass a possibly-multi-line value through `awk -v`.
- Tests are plain bash using `tests/helper.sh` asserts (`assert_eq`, `assert_contains`, `assert_file`, `assert_exit`, `setup_tmp`, `pass`). Each test does `cd "$(dirname "$0")"; . ./helper.sh; RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp` and passes `--dir "$DIR"`.
- Full suite runner: `for t in tests/test_*.sh; do bash "$t" || exit 1; done`.
- `dist/install.sh` is generated, never hand-edited — regenerate with `./bundle.sh`.

---

### Task 1: Fix `relay load` aborting on empty knowledge (Issue 1)

**Bug:** `_load_knowledge`'s final line is `[ -n "$out" ] && printf '%s' "$out"`. When the knowledge dir exists but holds no active facts/lessons (e.g. all were superseded/pruned/graduated) and the graduated count is below the soft cap, `out` is empty so the function returns 1. Under `set -e`, `kblock="$(_load_knowledge)"` in `cmd_load` then aborts the whole command — `relay load` prints nothing and exits 1, so the SessionStart hook delivers zero handoff context.

**Files:**
- Modify: `relay.sh` (`_load_knowledge`, final line ~159)
- Test: `tests/test_23_knowledge_load_empty.sh` (Create)

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

printf '## Summary\nhandoff body lives here\n' | "$RELAY" save --dir "$DIR" --digest "d"

# Add then retire the only fact and the only lesson, leaving empty facts/ + lessons/ dirs.
export RELAY_INSTRUCTION_FILE="$TMP/CLAUDE.md"
"$RELAY" knowledge add --fact   --id onlyfact "the build uses make"     --dir "$DIR" >/dev/null
"$RELAY" knowledge add --lesson --id onlylesson "always run the tests"  --dir "$DIR" >/dev/null
"$RELAY" knowledge supersede onlyfact --dir "$DIR" >/dev/null
"$RELAY" knowledge graduate onlylesson --dir "$DIR" >/dev/null 2>&1
# undo the graduated rule so the soft-cap nudge cannot mask the bug
"$RELAY" knowledge ungraduate onlylesson --dir "$DIR" >/dev/null 2>&1

# load MUST still succeed and still print the handoff
out="$("$RELAY" load --dir "$DIR")"; rc=$?
assert_eq "$rc" "0"
assert_contains "$out" "handoff body lives here"

# also: knowledge dir present but completely empty (only the dirs exist)
setup_tmp
printf '## Summary\nsecond handoff\n' | "$RELAY" save --dir "$DIR" --digest "d"
mkdir -p "$DIR/knowledge/facts" "$DIR/knowledge/lessons"
out="$("$RELAY" load --dir "$DIR")"; rc=$?
assert_eq "$rc" "0"
assert_contains "$out" "second handoff"

pass "knowledge load: empty/retired knowledge never aborts the handoff"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_23_knowledge_load_empty.sh`
Expected: FAIL (load exits 1, `out` empty → `assert_eq "$rc" "0"` or `assert_contains` fails). Note: because the test captures `rc` via `out="$(...)"; rc=$?`, the test script itself has `set -euo pipefail`, so the failing command substitution may abort the test before the assert — either way it does not pass.

- [ ] **Step 3: Implement the fix**

In `relay.sh`, change the end of `_load_knowledge` from:

```bash
  [ -n "$out" ] && printf '%s' "$out"
}
```

to:

```bash
  [ -n "$out" ] && printf '%s' "$out"
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_23_knowledge_load_empty.sh`
Expected: `PASS: knowledge load: empty/retired knowledge never aborts the handoff`

Also re-run the existing load test: `bash tests/test_19_knowledge_load.sh` → PASS.

---

### Task 2: Reject empty and over-length ids at creation (Issues 2 & 4)

**Bug (Issue 2):** A symbol-only `--id` (e.g. `--id '@@@'`) slugifies to the empty string. The entry is written to `knowledge/facts/.md` (a dotfile), `add` reports success with a blank id, and every reader glob (`*.md`) skips the dotfile — so the data is stored but invisible and unmanageable. A second empty-id add collides into the same file.

**Bug (Issue 4):** `_slugify` truncates to 48 chars (`cut -c1-48`). Two distinct ids differing only past char 48 collapse to the same slug → spurious conflict (facts) or silent body overwrite (lessons), and the stored id differs from what the user typed (so `why`/`graduate`/`resolve` need the truncated form).

**Fix:** Remove the silent truncation from `_slugify` and validate the slug at the one creation boundary (`k_add`): reject an empty slug and reject a slug longer than 48 chars, with a clear error and non-zero exit, before acquiring the lock.

**Files:**
- Modify: `relay.sh` (`_slugify` ~222-225; `k_add` ~468-469)
- Test: `tests/test_24_knowledge_id_validation.sh` (Create)

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

# Issue 2: symbol-only id is rejected (exit 2), nothing written.
assert_exit 2 "$RELAY" knowledge add --fact --id '@@@' "alpha body" --dir "$DIR"
[ -e "$DIR/knowledge/facts/.md" ] && { echo "FAIL: empty-slug dotfile was created"; exit 1; } || true

# Issue 4: two distinct long ids that share a 48-char prefix do NOT collide —
# they are rejected as too long rather than silently truncated/merged.
A="this-is-a-very-long-identifier-that-exceeds-forty-version-one"
B="this-is-a-very-long-identifier-that-exceeds-forty-version-two"
assert_exit 2 "$RELAY" knowledge add --fact --id "$A" "first fact about alpha" --dir "$DIR"
assert_exit 2 "$RELAY" knowledge add --fact --id "$B" "second fact about beta" --dir "$DIR"
# no truncated collision file exists
[ -e "$DIR/knowledge/facts/this-is-a-very-long-identifier-that-exceeds-fort.md" ] \
  && { echo "FAIL: over-length id was silently truncated"; exit 1; } || true

# Control: a normal id still works and stores its full slug verbatim.
"$RELAY" knowledge add --fact --id deploy-via-release "ships via release.sh" --dir "$DIR" >/dev/null
assert_file "$DIR/knowledge/facts/deploy-via-release.md"

pass "knowledge id validation: empty rejected, over-length rejected, normal id stored verbatim"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_24_knowledge_id_validation.sh`
Expected: FAIL — current code exits 0 on `--id '@@@'` (creates `.md`) and silently truncates the long ids, so the `assert_exit 2` / dotfile / truncation checks fail.

- [ ] **Step 3: Implement the fix**

In `relay.sh`, change `_slugify` to drop the truncation:

```bash
_slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' \
    | tr -s '-' | sed -e 's/^-//' -e 's/-$//'
}
```

(removed the trailing `| cut -c1-48`).

In `k_add`, immediately after `id="$(_slugify "$id")"` (and before `_lock`), add the guards:

```bash
  id="$(_slugify "$id")"
  [ -n "$id" ] || { echo "relay: --id slugifies to empty (need [a-z0-9] characters)" >&2; return 2; }
  [ "${#id}" -le 48 ] || { echo "relay: --id too long (${#id} chars after slugify; max 48): $id" >&2; return 2; }
  _lock || return 1
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_24_knowledge_id_validation.sh`
Expected: `PASS: knowledge id validation: empty rejected, over-length rejected, normal id stored verbatim`

Re-run the lesson/fact tests to confirm no regression: `bash tests/test_11_knowledge_lesson.sh && bash tests/test_12_knowledge_fact.sh` → PASS.

---

### Task 3: Multi-line fact confirm no longer raises a spurious conflict (Issue 3)

**Bug:** `_dice` passes the stored body to `awk -v A="$1"`. BSD awk (macOS default) rejects a newline inside a `-v` value (`awk: newline in string`), so `_dice` outputs nothing, `_similar` errors, and re-confirming a byte-identical multi-line fact raises a bogus conflict instead of incrementing `confirmed`. The same multi-line hazard was already solved in `_block_upsert` by passing the body through a file.

**Fix:** Rewrite `_dice` to read both bodies from files (via `awk`'s positional file args + `FNR==NR`), never `-v`.

**Files:**
- Modify: `relay.sh` (`_dice` ~293-303)
- Test: `tests/test_25_knowledge_multiline_fact.sh` (Create)

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

BODY="$(printf 'line one about the make build\nline two about the docker image')"
"$RELAY" knowledge add --fact --id ml "$BODY" --dir "$DIR" >/dev/null

# Re-adding the identical multi-line body must CONFIRM, not conflict.
out="$("$RELAY" knowledge add --fact --id ml "$BODY" --dir "$DIR" 2>&1)"
assert_contains "$out" "confirmed: ml"
[ -e "$DIR/knowledge/facts/ml.conflict" ] && { echo "FAIL: spurious conflict on identical multi-line fact"; exit 1; } || true

# A genuinely different body still raises a conflict (similarity logic intact).
out="$("$RELAY" knowledge add --fact --id ml "completely unrelated content xyzzy plugh" --dir "$DIR" 2>&1)"
assert_contains "$out" "conflict raised"
assert_file "$DIR/knowledge/facts/ml.conflict"

pass "knowledge multi-line fact: identical body confirms, divergent body conflicts"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_25_knowledge_multiline_fact.sh`
Expected: FAIL — on BSD awk the re-confirm raises a conflict (`assert_contains "$out" "confirmed: ml"` fails / `ml.conflict` exists).

- [ ] **Step 3: Implement the fix**

In `relay.sh`, replace `_dice` with a file-based version:

```bash
_dice() { # bodyA bodyB -> integer 0..100 (Dice coefficient over unique lowercase tokens)
  local fa fb r
  fa="$(mktemp)"; fb="$(mktemp)"
  printf '%s' "$1" > "$fa"; printf '%s' "$2" > "$fb"
  r="$(awk '
    FNR==NR { n=split(tolower($0),w,/[^a-z0-9]+/); for(i=1;i<=n;i++) if(w[i]!="") sa[w[i]]=1; next }
            { n=split(tolower($0),w,/[^a-z0-9]+/); for(i=1;i<=n;i++) if(w[i]!="") sb[w[i]]=1 }
    END{ ca=0; for(k in sa) ca++; cb=0; for(k in sb) cb++;
         inter=0; for(k in sa) if(k in sb) inter++;
         if(ca+cb==0){ print 0; exit }
         printf "%d", (inter*200)/(ca+cb) }' "$fa" "$fb")"
  rm -f "$fa" "$fb"
  printf '%s' "$r"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_25_knowledge_multiline_fact.sh`
Expected: `PASS: knowledge multi-line fact: identical body confirms, divergent body conflicts`

Re-run the fact test to confirm single-line similarity still works: `bash tests/test_12_knowledge_fact.sh` → PASS.

---

### Task 4: Regenerate bundle and verify the whole suite

**Files:**
- Modify: `dist/install.sh` (regenerated by `./bundle.sh`, not hand-edited)

- [ ] **Step 1: Regenerate the bundle**

Run: `./bundle.sh`
Expected: `wrote dist/install.sh`

- [ ] **Step 2: Run the full test suite**

Run: `for t in tests/test_*.sh; do echo "== $t =="; bash "$t" || { echo "SUITE FAIL: $t"; exit 1; }; done`
Expected: every test prints `PASS:`; no `FAIL`/`SUITE FAIL`. Must include test_21 (bundle regen / install e2e) green, confirming `dist/install.sh` matches the fixed `relay.sh`.

- [ ] **Step 3: Commit**

```bash
git add relay.sh dist/install.sh \
  tests/test_23_knowledge_load_empty.sh \
  tests/test_24_knowledge_id_validation.sh \
  tests/test_25_knowledge_multiline_fact.sh \
  docs/superpowers/plans/2026-06-23-relay-knowledge-bugfixes.md
git commit -m "fix(relay): harden knowledge load + id validation + multi-line dice; rebuild bundle"
```

---

## Self-Review

- **Spec coverage:** Issue 1 → Task 1; Issues 2 & 4 → Task 2; Issue 3 → Task 3; bundle/suite → Task 4. All four bugs covered.
- **Placeholder scan:** No TBD/TODO; every code step shows the exact code.
- **Type consistency:** `_slugify`, `_dice`, `_load_knowledge`, `k_add` signatures unchanged externally; only internal bodies change. `_dice` still emits an integer 0..100; `_similar`'s `[ "$(_dice …)" -ge 50 ]` contract holds.
- **Risk:** Removing `cut -c1-48` from `_slugify` affects all callers, but every existing stored id is ≤48 chars and all existing tests use short ids, so lookups are unaffected; new over-length ids are now rejected at creation rather than silently truncated.

---

## Rotation 2 — issues found by the rotation-1 review

The rotation-1 code review confirmed the three fixes above are correct, and surfaced three further real correctness bugs (plus one false positive). Each is fixed TDD-style below.

**False positive (not fixed):** `_load_knowledge`'s `printf '%03d'` on a non-numeric `confirmed:` value. The bash *builtin* printf (what the script uses) prints a stderr diagnostic and continues; and the printf sits in a `for`-loop body, which is exempt from `set -e`. So `relay load` does NOT abort on corrupted frontmatter — verified `EXIT=0`. The reviewer tested external `/usr/bin/printf` (returns 1), which the script never invokes. Worst case is cosmetic stderr noise + a mis-sorted entry; no fix warranted.

### Task 5: `k_resolve --keep new` must not abort when the fact file is missing (Issue 5)

**Bug:** `k_resolve` guards only on the `.conflict` file, then runs `cp "$f" …` unconditionally. If `facts/$id.md` is absent while `facts/$id.conflict` is pending (e.g. the fact was superseded/removed out-of-band leaving an orphan conflict), `cp` fails under `set -e`: the command dies with a raw `cp:` error (exit 1), `rm -f "$cf"` never runs, and the conflict stays pending forever.

**Files:** Modify `relay.sh` (`k_resolve` ~361-364); Test `tests/test_26_knowledge_resolve_missing.sh` (Create)

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

"$RELAY" knowledge add --fact --id g "original body about make" --dir "$DIR" >/dev/null
# orphan conflict: pending conflict but the fact .md is gone
printf 'a different body entirely\n' > "$DIR/knowledge/facts/g.conflict"
rm -f "$DIR/knowledge/facts/g.md"

rc=0; out="$("$RELAY" knowledge resolve --keep new g --dir "$DIR" 2>&1)" || rc=$?
assert_eq "$rc" "0"
assert_contains "$out" "resolved: g"
assert_file "$DIR/knowledge/facts/g.md"
assert_contains "$(cat "$DIR/knowledge/facts/g.md")" "a different body entirely"
[ -e "$DIR/knowledge/facts/g.conflict" ] && { echo "FAIL: conflict left pending"; exit 1; } || true

pass "knowledge resolve: --keep new recreates fact and clears conflict when .md is missing"
```

- [ ] **Step 2: Run → FAIL** (`cp` aborts, rc≠0, conflict left)
- [ ] **Step 3: Fix** — in `k_resolve`, guard the `--keep new` branch:

```bash
  if [ "$keep" = new ]; then
    if [ -f "$f" ]; then
      cp "$f" "$(_uniq_dest "$DATA/knowledge/facts/superseded/$id.original.md")"
      _set_body "$f" "$(cat "$cf")"
      _fm_set "$f" last_confirmed "$(date +%F)"
    else
      _write_fact "$f" "$id" 1 "$(date +%F)" "$(date +%F)" none "$(_provenance)" "$(cat "$cf")"
    fi
  else
```

- [ ] **Step 4: Run → PASS**

### Task 6: `k_supersede` must scope its conflict removal to the kind it superseded (Issue 6)

**Bug:** Inside `for kind in facts lessons`, the cleanup line is hard-coded `rm -f "$DATA/knowledge/facts/$id.conflict"`. When the `lessons` iteration runs, it deletes a same-named *fact's* conflict that is not being superseded, dropping pending fact-resolution state.

**Files:** Modify `relay.sh` (`k_supersede` ~564); Test `tests/test_27_knowledge_supersede_scope.sh` (Create)

- [ ] **Step 1: Failing test**

```bash
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
```

- [ ] **Step 2: Run → FAIL** (conflict deleted)
- [ ] **Step 3: Fix** — change the cleanup line to `rm -f "$DATA/knowledge/$kind/$id.conflict"`
- [ ] **Step 4: Run → PASS**

### Task 7: `k_why` must not silently shadow a same-id fact with a lesson (Issue 7)

**Bug:** `for k in facts lessons; do [ -f … ] && f=…; done` keeps the *last* match, so when an id exists as both a fact and a lesson, `why` always shows the lesson and never the fact, with no indication of the collision.

**Files:** Modify `relay.sh` (`k_why` ~597); Test `tests/test_28_knowledge_why_firstmatch.sh` (Create)

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

"$RELAY" knowledge add --fact   --id dup "the fact body sentinel FACTONLY" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --lesson --id dup "the lesson body sentinel LESSONONLY" --dir "$DIR" >/dev/null

out="$("$RELAY" knowledge why dup --dir "$DIR")"
assert_contains "$out" "FACTONLY"   # first match (fact) is shown deterministically

pass "knowledge why: first match (fact) wins; no silent lesson shadow"
```

- [ ] **Step 2: Run → FAIL** (lesson shown, FACTONLY absent)
- [ ] **Step 3: Fix** — `for k in facts lessons; do [ -f "$DATA/knowledge/$k/$id.md" ] && { f="$DATA/knowledge/$k/$id.md"; break; }; done`
- [ ] **Step 4: Run → PASS**

### Task 8: Rebuild bundle + full suite (rotation 2)

- [ ] `bash bundle.sh`
- [ ] `for t in tests/test_*.sh; do bash "$t" || exit 1; done` → all PASS
- [ ] Commit

---

## Rotation 3 — issue found by the rotation-2 review

The rotation-2 review confirmed rotation-2's three fixes are correct and surfaced one more real (low-severity) bug.

### Task 9: graduated-block nudge must not emit a malformed `gcount` (Issue 8)

**Bug:** In `_load_knowledge`, `gcount="$(grep -cF '<!-- relay:learned:' "$instr" 2>/dev/null || printf 0)"`. When the instruction file exists but has zero graduated markers (the common default for any repo with a `CLAUDE.md`), `grep -c` prints `0` **and** exits 1, so the `|| printf 0` appends a second `0` → `gcount` becomes `"0\n0"`. The next line `[ "${gcount:-0}" -ge … ]` then prints `relay.sh: line 154: [: 0\n0: integer expression expected` to stderr on every `relay load`. It does not abort (the test sits in an `if` condition, set -e exempt) and the warning correctly stays silent, but it pollutes the SessionStart hook's stderr every session.

**Fix:** Use the assignment-fallback form (like `cmd_save`'s `n=$(…) || n=0`), so the fallback replaces rather than appends.

**Files:** Modify `relay.sh` (`_load_knowledge` ~153); Test `tests/test_29_knowledge_load_clean_stderr.sh` (Create)

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

printf '## S\nbody\n' | "$RELAY" save --dir "$DIR" --digest d
"$RELAY" knowledge add --fact --id ok "valid fact body" --dir "$DIR" >/dev/null
# instruction file exists but has zero graduated markers (common default)
export RELAY_INSTRUCTION_FILE="$TMP/CLAUDE.md"
printf '# Project\nsome instructions\n' > "$RELAY_INSTRUCTION_FILE"

err="$("$RELAY" load --dir "$DIR" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q 'integer expression' && { echo "FAIL: load leaked: $err"; exit 1; } || true

pass "knowledge load: graduated-nudge count is clean (no stderr noise) with zero markers"
```

- [ ] **Step 2: Run → FAIL** (stderr has `integer expression expected`)
- [ ] **Step 3: Fix** — replace the `gcount` line with:

```bash
    gcount="$(grep -cF '<!-- relay:learned:' "$instr" 2>/dev/null)" || gcount=0
```

- [ ] **Step 4: Run → PASS**

### Task 10: Rebuild bundle + full suite (rotation 3)

- [ ] `bash bundle.sh`
- [ ] `for t in tests/test_*.sh; do bash "$t" || exit 1; done` → all PASS
- [ ] Commit

---

## Rotation 4 — issue found by the rotation-3 review

### Task 11: Validate `--ttl` at creation (Issue 9)

**Bug:** `k_add` accepts `--ttl <value>` with no validation and stores it verbatim (`ttl: abc`, `ttl: 30d`). At load (`_load_knowledge` ~112) and prune (`k_prune` ~595), `[ "$age" -gt "$lim" ]` runs with a non-numeric `lim`, which (a) prints `relay.sh: line N: [: <val>: integer expression expected` to stderr on every `relay load` — the SessionStart hook path — and (b) evaluates false, so the fact is **never** counted as expired and never pruned: the TTL/freshness mechanism is silently defeated for that fact. No abort (both comparisons are in `for`-loop bodies → set -e exempt). A user/agent typing `--ttl 30d` (expecting "30 days") hits this immediately.

**Fix:** Validate `--ttl` in `k_add`: accept `none` or a non-negative integer (days); reject anything else with exit 2, before the value reaches disk. Use a POSIX `case` glob (no subprocess).

**Files:** Modify `relay.sh` (`k_add`, after the id guards, before `_lock`); Test `tests/test_30_knowledge_ttl_validation.sh` (Create)

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp

# non-integer ttl rejected (exit 2), nothing written
assert_exit 2 "$RELAY" knowledge add --fact --id t1 --ttl 30d "body about a thing" --dir "$DIR"
assert_exit 2 "$RELAY" knowledge add --fact --id t2 --ttl abc "body about a thing" --dir "$DIR"
[ -e "$DIR/knowledge/facts/t1.md" ] && { echo "FAIL: t1 written despite bad ttl"; exit 1; } || true

# valid ttls still accepted: integer and the literal 'none'
"$RELAY" knowledge add --fact --id t3 --ttl 30   "body three about a thing" --dir "$DIR" >/dev/null
"$RELAY" knowledge add --fact --id t4 --ttl none "body four about a thing" --dir "$DIR" >/dev/null
assert_file "$DIR/knowledge/facts/t3.md"
assert_file "$DIR/knowledge/facts/t4.md"

# load with the valid-ttl fact present emits no integer-expression noise
printf '## S\nbody\n' | "$RELAY" save --dir "$DIR" --digest d
err="$("$RELAY" load --dir "$DIR" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q 'integer expression' && { echo "FAIL: load leaked: $err"; exit 1; } || true

pass "knowledge ttl validation: non-integer rejected, integer/none accepted, no load noise"
```

- [ ] **Step 2: Run → FAIL** (bad ttl accepted; stored verbatim)
- [ ] **Step 3: Fix** — in `k_add`, after the `[ "${#id}" -le 48 ]` guard and before `_lock`:

```bash
  if [ "$ttl" != none ]; then
    case "$ttl" in
      ''|*[!0-9]*) echo "relay: --ttl must be 'none' or a non-negative integer (days): $ttl" >&2; return 2 ;;
    esac
  fi
```

- [ ] **Step 4: Run → PASS**

### Task 12: Rebuild bundle + full suite (rotation 4)

- [ ] `bash bundle.sh`
- [ ] `for t in tests/test_*.sh; do bash "$t" || exit 1; done` → all PASS
- [ ] Commit
