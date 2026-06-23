# Relay — Portable Learning + Memory: Design Spec

- **Date:** 2026-06-22 (revised 2026-06-22 after Cognitive Forge design review)
- **Status:** Draft — hardened post-review; ready for plan gate
- **Author:** Jeremy Brice (with Claude)
- **Type:** New capability layer on Relay v1 (handoff core already shipped)
- **Relates to:** `design-spec.md` (Relay v1 handoff core), `full-day-load-design-spec.md`
  (load-path enhancement), `2026-06-22-relay-learning-design-review.md` (the review this
  revision answers). Extends the same deterministic helper + thin-adapter architecture.
- **Relates to (origin system):** the Forge learning loop (`.forge/learning/`,
  `/analyze-learning`, `/evolve`) and Forge Memory (`memory/`) — a deliberately *lightened*
  port of the idea (capture → reinforce → graduate), not the machinery (cron, batch analysis,
  confidence math, decay).

> **2026-06-22 post-review revision.** A three-agent Cognitive Forge review (challenger /
> explorer / decomposer) found the v1 draft's determinism was broken at one seam — the
> `id`/slug contract — with `index.md` consistency as the second concentrated risk, and three
> holes in graduation. This revision answers all six critical issues and folds in the keystone
> enhancements (helper-stamped provenance, a fact `confirmed` counter, `--near` dedup, TTL lazy
> revalidation, git-style conflict markers, graduated-lesson back-pointers). The architecture is
> unchanged; the contracts are now pinned. Each fix is marked **[R#]** against the review's
> critical-issue numbering. Full review: `2026-06-22-relay-learning-design-review.md`.

---

## 1. Problem & driver

Relay v1 gives a fresh agent the last session's handoff — but a handoff is *ephemeral* (pruned
at 10 days), so nothing accumulates *durable* knowledge: what is permanently true about the repo,
or what the agent has learned about how to work in it.

**Driver: dogfood reach.** Relay already lives in non-Forge repos (e.g. `html-review-tool`). The
goal is for those repos to get *smarter agents over time* the way the Forge workspace does —
without requiring each repo to run a daemon. That hard constraint shapes every decision:
**a dogfood repo has no daemon**, so Forge's passive half (SessionObserver cron, scheduled
`/analyze-learning`) does not transfer. Learning must be **active** (agent-authored at save) and
**deterministic in mechanics** (the helper does all file ops).

## 2. Goals

- A Relay repo accumulates **durable knowledge** that survives the rolling 10-day window.
- Knowledge is captured **actively**, piggybacking on the existing save — no daemon, no cron.
- The self-learning loop (a pattern gets *more established* with recurrence and eventually
  *graduates* into a standing instruction) is preserved in a **lightweight** form.
- Token budget at load stays bounded **and gaps are never silent** — if knowledge is truncated,
  the agent is told so (the full-day-load spec's anti-silent-continuity principle, applied here).
- The store does not become bloated or stale over a 6-month horizon.
- **Local-only for now**, with the one operation that can leak to a committed file (graduation)
  made explicit and gated.

## 3. Non-goals (deliberately cut)

- No cron, background observation capture, or batch analyzer.
- No confidence-*score* math or decay curves — a recurrence counter, a freshness TTL, and a
  threshold only.
- No committed/shared store by default (a gated `export` and the graduation block are the only
  ways knowledge leaves the local machine; both are explicit).
- No cross-repo knowledge aggregation.
- No auto-graduation by default (a toggle exists, off by default).

## 4. Architecture — two tiers over one helper

Relay's four-part shape (installer · adapters · core helper · data) is unchanged. The Core's
`relay.sh` gains `knowledge` subcommands; each adapter gains one capture instruction and one
standalone command. Two data tiers, **both local-only and gitignored**, under the existing
`.session-log/` directory so the gitignore footprint stays one line:

- **Tier 1 — ephemeral handoffs** (`latest.md`, `index.md`, `history/`). Unchanged. Pruned at 10 days.
- **Tier 2 — durable knowledge** (`knowledge/`). New. Never pruned by age.

**Boundary invariant (clarified per [R-determinism]).** Knowledge is plain markdown readable with
no adapter; `relay.sh` owns every file write, counter, merge, and the index — these are fully
deterministic. The agent owns *judgment* (is this durable? which existing entry does it match?
which side of a contradiction is current?). The honest framing the review demanded: **the
mechanics are deterministic; the create-vs-merge-vs-conflict *outcome* is agent-determined**, and
the helper's job is to make that judgment *cheap, visible, and reversible* (via `--near`,
conflict markers, and tombstones), never to pretend the judgment is the helper's.

## 5. Data structure — per-entry files + a derived index

One file per entry, keyed by a stable slug `id`. Mirrors how Forge stores instincts, how
auto-memory stores facts, and how `relay.sh` already treats `history/<date>.md` (filename = key).
The decisive reason is the **deterministic counter-bump**: rewriting one small single-purpose
file is atomic; surgically editing a block inside a growing flat file is the corruption-prone
operation.

```
.session-log/knowledge/
  index.md                       # DERIVED CACHE — rebuilt from entry files on every locked op
  facts/
    deploy-release-script.md     # one fact per file
    test-db-resets.md
  facts/superseded/              # retired/lost-conflict facts (tombstones, not deleted)
  lessons/
    schema-types-first.md        # one active lesson per file
  lessons/graduated/             # lessons moved here on graduation (tombstone + back-pointer)
  lessons/superseded/            # retired lessons (tombstone, not deleted)
```

### 5.1 `index.md` is a derived cache, not an authored file  **[R4]**

The review's highest-leverage fix. `index.md` is **regenerated from scratch by scanning the
entry files on every locked mutating op** — never hand-edited line-by-line. This converts
index↔files drift from a silent-correctness bug into a structural impossibility, and it removes
the surgical-edit-to-a-growing-flat-file hazard that per-entry files were chosen to avoid.

- Rebuild glob is **depth-1 and tombstone-excluding**: `facts/*.md` and `lessons/*.md` only —
  never `**/*.md` (so `superseded/` and `graduated/` never count as active).
- The line format carries **every field any ranker consumes**, so load stays O(index):
  ```
  fact   · <id> · confirmed:N · last:YYYY-MM-DD · ttl:DAYS|none · conflict:0|1
  lesson · <id> · seen:N · sessions:M · last:YYYY-MM-DD · status:active
  ```
- Cost is O(entry-files) per write. At this store's scale (tens to low-hundreds of tiny files)
  that is milliseconds and safe; correctness beats a micro-optimization.

### 5.2 Entry schemas (helper-stamped provenance)  **[R-enh: provenance]**

The helper stamps `source` (it already knows today's date and session N from `cmd_save`) and all
counters/dates. The agent authors only `id` and body.

**Fact** (`facts/<id>.md`):
```markdown
---
id: deploy-release-script
kind: fact
confirmed: 3                 # bumped each time the agent re-asserts this id (reinforcement proxy)
first_seen: 2026-06-18
last_confirmed: 2026-06-22
ttl: none                    # optional freshness window in days; "none" = near-permanent
source: history/2026-06-22.md#session-2   # helper-stamped provenance
status: active               # active | superseded
---
Deploys ship via scripts/release.sh — never `npm publish` directly.
```

**Lesson** (`lessons/<id>.md`):
```markdown
---
id: schema-types-first
kind: lesson
seen: 3
sessions: 3                  # count of DISTINCT dates seen on (graduation gate, not raw seen)  [R6]
first_seen: 2026-06-18
last_seen: 2026-06-22
source: history/2026-06-22.md#session-2
status: active               # active | graduated | superseded
graduated_to: null           # set to the instruction file + marker id on graduation  [R-enh]
---
When editing the DB schema, regenerate types before touching call-sites —
last time a stale type shipped a runtime mismatch.
```

## 6. Capture — one reflection, three destinations (piggybacks on save)

At wrap-up the agent runs `/session-save` (or `$session-save`); its single reflection routes into:

1. **"What happened today"** → the 6-section handoff (`relay save`, unchanged).
2. **"What's now permanently true here"** → a Fact (`relay knowledge add --fact --id <slug>`).
3. **"What I learned about how to work here"** → a Lesson (`relay knowledge add --lesson --id <slug>`).

### 6.1 The fact `id` contract  **[R1]**

Resolved: **facts take an explicit `--id`, exactly like lessons** (the v1 draft's `--fact "…"`
with no id was the central self-contradiction). Slug rules are pinned and deterministic:
lower-case, spaces/underscores → dash, strip punctuation except dash, collapse repeats, cap at 48
chars. The agent supplies the slug; the helper validates/normalizes it.

### 6.2 `--near` — dedup before you coin a new slug  **[R2, R-enh]**

Before creating a *new* fact, the agent is instructed to run `relay knowledge add --fact --near
"<text>"`: the helper greps existing fact bodies/ids for token overlap and prints the **top-3
candidate ids** for the agent to reuse instead of minting a duplicate. The helper does the grep
(deterministic); the agent picks the match (judgment). This is the package-manager-resolver
pattern and the structural mitigation for the one determinism-boundary leak (agent slug
stability across sessions *and* across the two harnesses).

### 6.3 Confirm vs. conflict — never silent overwrite  **[R2]**

When the agent adds a fact whose `id` already exists, the helper **diffs the new body against the
stored one**:

- **Materially similar** (or the agent explicitly confirms) → **confirm**: bump `confirmed`,
  refresh `last_confirmed`. No overwrite of meaning.
- **Materially divergent** → **conflict, not overwrite** (git's "never auto-resolve, always
  surface" discipline): the helper writes the new body into a `<!-- relay:conflict -->` block
  *alongside* the existing one, sets `conflict:1` in the index, and flags it at load. A
  `relay knowledge resolve <id>` lets the agent/user keep one side (the loser is tombstoned to
  `facts/superseded/`). This gives facts the supersession-by-contradiction the v1 draft lacked,
  and closes the silent-overwrite data-loss path.

A standalone `/relay-learn` / `$relay-learn` hits the same helper for mid-session capture.

## 7. Lesson lifecycle — the learning engine

- **Capture:** file created at `seen: 1`, `sessions: 1`.
- **Reinforce:** re-asserting the same `id` bumps `seen`, refreshes `last_seen`, and increments
  `sessions` **only when the date differs from the last** (so the gate counts distinct days, not
  same-session repeats).
- **Graduate (gated) at threshold [R6]:** when `sessions >= RELAY_GRADUATE_AT` (default 3 distinct
  sessions on distinct dates — *not* a bare `seen` counter, which can't tell coincidence from
  pattern), the agent *proposes* graduation; on user approval `relay knowledge graduate <id>`:
  1. **Idempotent instruction-block write first**, keyed on lesson id —
     `<!-- relay:learned:schema-types-first -->` … inside the single `<!-- relay:learned -->`
     region of `CLAUDE.md`/`AGENTS.md`. Re-running is a no-op (crash-retry converges). **[R-struct]**
  2. Flip `status: graduated`, set `graduated_to`, move file to `lessons/graduated/`.
  3. Rebuild `index.md`.
  Graduation is **gated** because writing a standing instruction is a persistent, behavior-changing
  edit (workspace decision-threshold rules). `RELAY_AUTO_GRADUATE` exists, off by default.
- **Ungraduate / supersede [R5]:** a graduated rule that goes stale is retired by
  `relay knowledge ungraduate <id>` — idempotently removes that id's lines from the marked block,
  flips status, tombstones to `lessons/superseded/`. `relay knowledge supersede <id>` does the
  same for a still-active lesson. No graduated text is ever orphaned without a removal path.
- **Drift detection [R-enh]:** `graduated_to` is a back-pointer; `relay knowledge list` flags a
  graduated lesson whose `CLAUDE.md` line a human deleted (knowledge would otherwise vanish).

### 7.1 Honest framing of graduation vs. budget  **[R5]**

The v1 draft called graduation "budget control." Corrected: graduation **relocates** a lesson
from Relay's capped injected store into the instruction file the harness loads natively — it
keeps *Relay's* injected block small but the instruction file itself is **uncapped**. So the
`<!-- relay:learned -->` region needs its own discipline: at load the helper emits a one-line
nudge if the region exceeds a soft size ("8 graduated rules — review/consolidate?"), and
`ungraduate` is the drain. Graduation is net-positive for Relay's budget, not a free lunch for
total context.

### 7.2 Graduation is the one local-to-committed leak  **[R5]**

`CLAUDE.md`/`AGENTS.md` is normally committed. So graduation is the single operation that can move
gitignored, local-only learning into a shared, committed standing instruction — silently changing
a teammate's agent behavior. This is now **explicit**: graduation always prompts, names that it
writes to a committed file, and leaves the commit decision to the user. Until you choose to enable
sharing, treat graduation as "writes to your working tree; you decide whether it travels."

## 8. Facts lifecycle — hardened (was the weakest link)

Facts have no graduation drain, so their lifecycle is now built from four daemon-free controls:

- **Confirm-and-reinforce, never silent-overwrite (§6.3).** Re-assertion bumps `confirmed`;
  divergence raises a conflict. `confirmed` is a free confidence proxy with no math.
- **`--near` dedup at write (§6.2)** so duplicates are caught before they exist.
- **TTL lazy revalidation [R-enh, R-staleness].** Each fact carries an optional agent-set `ttl`
  (deploy-command → `none`; "current sprint is X" → 14). At load the helper deterministically
  compares `last_confirmed + ttl` to today and flags **only expired** facts — the *read is the
  revalidation trigger* (DNS/cache pattern), so staleness needs no scheduler. This answers the
  review's "staleness control needs something to fire in a daemon-less repo."
- **Gated prune.** `relay knowledge prune` proposes expired/low-`confirmed`/old facts for
  user-approved removal. Never auto-deletes; never on a scheduler.

Ranking at load is by **reinforcement, not date alone**: `confirmed × recency`, so an
old-but-constantly-reaffirmed fact ranks above a once-seen-then-forgotten one.

## 9. Load — bounded, but never silent  **[R3]**

All injected by `cmd_load` (one change flows to both harnesses; Codex JSON-escapes the same
string into `systemMessage`). Knowledge loads under its **own** word budget, separate from the
handoff cap. Injection order:

1. Recency line (⚠ stale flag > 3 days).
2. `latest.md` headline — full, `RELAY_WORD_CAP`.
3. Today's earlier sessions (multi-session days; per full-day-load spec).
4. **Facts** — ranked by `confirmed × recency`, `RELAY_FACTS_CAP`.
5. **Active lessons** — ranked by `seen` desc, `RELAY_LESSONS_CAP`.
6. `index.md` (handoff) verbatim.
7. On-demand pointer (history + knowledge).

**Truncation is never silent (the core [R3] fix, aligning with `full-day-load-design-spec` §3.1).**
If facts or lessons exceed their cap, the load emits an explicit count, not a quiet drop:
`⚠ 14 of 31 facts shown — 17 not loaded may include load-bearing truths; open knowledge/facts/`.
The agent therefore *knows it is incomplete* and never answers "what's true here" confidently-partial.
Load also surfaces, in one compact line each: TTL-expired facts, pending conflicts, and an
oversized graduated-block nudge.

Optional header (cheap, high-signal): `This repo knows: 31 facts · 6 active lessons · 4 graduated`.

## 10. Hooks & adapters (symmetric)

| Operation | Claude Code | Codex |
|---|---|---|
| Load | `SessionStart` hook → `relay load` → stdout into context | `SessionStart` hook → `relay load --format codex` → `systemMessage` JSON |
| Save L1 | `/session-save` → handoff + knowledge capture | `$session-save` → handoff + knowledge capture |
| Learn (new) | `/relay-learn` → `relay knowledge add` | `$relay-learn` → `relay knowledge add` |
| Save L2 | CLAUDE.md prompt: capture facts/lessons (`--near` first) + surface graduation-ready | AGENTS.md prompt: same |
| Graduation target | `<!-- relay:learned -->` region in CLAUDE.md | same region in AGENTS.md |
| Hook config | `.claude/settings.json` | `.codex/config.toml` `[hooks]` |

Load-hook wiring is untouched — it just emits more. All knowledge logic lives in shared `cmd_load`
/ `relay.sh`, so the two harnesses cannot drift.

## 11. Command surface

Mechanics deterministic; the create/merge/conflict **outcome** is agent-determined (§4) — `--near`
and conflict markers make that judgment cheap, visible, and reversible.

```
relay knowledge add --fact   --id <slug> "…"        # create (confirmed:1) | confirm | raise conflict
relay knowledge add --fact   --near "…"             # show top-3 existing candidate ids, don't write
relay knowledge add --lesson --id <slug> "…"        # create (seen:1) | reinforce (bump seen/sessions)
relay knowledge resolve   <id>                      # pick a side of a fact conflict; tombstone loser
relay knowledge graduate  <id>                      # idempotent block write → status flip → index rebuild
relay knowledge ungraduate <id>                     # remove from block (idempotent) → tombstone
relay knowledge supersede <id>                      # retire an active entry (tombstone)
relay knowledge prune                               # propose expired/stale facts for gated removal
relay knowledge why   <id>                           # cat entry + its source handoff section (audit)
relay knowledge list                                # current state + drift/conflict flags
relay knowledge export                              # concat active entries → one shareable markdown (gated)
relay load [--format codex]                         # now also emits facts + active lessons (+ non-silent caps)
```

The agent never edits knowledge files directly — that is what makes counters trustworthy, the
index a safe derived cache, and graduation idempotent.

## 12. Repo impact

| Touch point | Change | Git status |
|---|---|---|
| `.relay/relay.sh` | extended | committed — new `knowledge` subcommands + index rebuilder + load injection |
| `.session-log/knowledge/**` | new | git-ignored — local-only durable data |
| `CLAUDE.md` / `AGENTS.md` | + marked region | the one local→committed leak; gated; **you** choose to commit |
| `.claude/settings.json` · `.codex/config.toml` | unchanged | load hook already wired |
| adapter skills/commands | + `/relay-learn` + capture instruction | committed |
| `.gitignore` | unchanged | existing `.session-log/` entry covers `knowledge/` |

## 13. Implementation notes & sequencing  **[R-struct]**

Strict build order (foundation-first): **(1)** the `index.md` derived-cache rebuilder (the
keystone — every op calls it) → **(2)** the fact/lesson `id` contract + slug normalization →
**(3)** `add` (create / confirm / conflict, with `--near`) → **(4)** `load` (rank/cap from index,
non-silent truncation) → **(5)** `graduate`/`ungraduate` (idempotent marked-block editor) →
**(6)** `supersede` / `prune` / `resolve` / `why` / `export`.

Pinned deterministic-but-fragile points:
- **Date math is BSD-form** (`date -j -f "%Y-%m-%d"`), not GNU `date -d` — Relay targets bash 3.2
  on stock macOS. Reuse v1's existing `to_epoch` fallback.
- **The marked-block editor** (`awk`/`sed` range edit, keyed per-id) is the most fragile op and
  carries a 4-case test matrix: no region / region exists / region already has this id /
  markers malformed or hand-edited.

## 14. Testing strategy (extends the zero-dep suite)

- `add --fact` new id → file + `confirmed:1`; re-add similar → confirm (no dup); re-add **divergent**
  → conflict block raised, **not** overwrite; `resolve` tombstones the loser. **[R2]**
- `--near` → prints existing candidate ids, writes nothing.
- `add --lesson` → `seen:1`,`sessions:1`; re-add same day → `seen` bumps, `sessions` unchanged;
  re-add a later day → `sessions` increments. **[R6]**
- Graduation at `sessions>=3` → appends id-keyed block; run twice → idempotent (no dup); crash
  between steps then retry → converges, never double-injects. `ungraduate` → removes block lines
  idempotently. **[R5, R-struct]**
- `index.md` is regenerated from files each op; tombstone subdirs excluded; reflects exactly the
  active set; carries every rank field. **[R4]**
- Load: facts ranked by `confirmed × recency`; over-cap → **explicit "N of M shown"** line, not a
  silent drop; TTL-expired + conflicts + oversized-graduated-block nudges surfaced; graduated
  lessons not double-injected. **[R3]**
- `prune` proposes only expired/stale; `why` cats entry + source; provenance stamped on every write.
- Codex `--format codex` → well-formed JSON with knowledge present (quotes/backslash/tab).
