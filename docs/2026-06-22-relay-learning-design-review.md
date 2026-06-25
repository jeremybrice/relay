---
type: design-review
spec: projects/relay/docs/2026-06-22-relay-learning-design.md
date: 2026-06-22
agents: [challenger, explorer, decomposer, synthesizer]
context_files: [projects/relay/docs/design-spec.md, projects/relay/docs/full-day-load-design-spec.md]
---

## Synthesis

### Core Thread

All three agents converge on one structural truth: **Relay-learning's identity as a deterministic tool is broken at exactly one seam — the `id`/slug contract — and every named failure radiates from it.** The Decomposer names it as the central undefined boundary (§6 `add --fact` has no `--id`, but §8 confirm-and-merge keys on a matching `id`); the Challenger shows what that gap *does* (slug-collision silently overwrites a real fact; slug-divergence accretes duplicates); the Explorer supplies the cheapest fixes (provenance, `--near` dedup, conflict markers). The deeper insight: the spec self-describes as "all deterministic" (§11), but the **outcome** of every knowledge write — create vs. merge vs. overwrite — is decided by an unverified LLM judgment about semantic identity. The file write is deterministic; the decision selecting which file is not. The index.md keystone, the facts cap, and graduation all inherit their fragility from this root.

### Tension Map

1. **Facts cap acceptable or fatal?** Challenger: fatal — reintroduces the silent-partial-continuity the sibling full-day-load spec was written to kill, on the same load path. Explorer routes around it with a `confirmed` counter. *Productive, but Challenger wins the headline:* resolve the contradiction at spec level, use Explorer's ranking signal as the mechanism.
2. **index.md incremental vs. full rebuild.** Decomposer resolves: derived cache, full-rebuilt every locked op → drift becomes structurally impossible. *Decomposer wins;* the spec's current "maintain inside the locked write" is the incremental approach that re-creates the corruption per-entry files were chosen to avoid.
3. **Ship graduation in v1?** Challenger argues it has three holes (uncapped surface, no retirement path, local-only leak). Explorer/Decomposer assume it stays. *Productive:* keep it (it's the signature feature) but close the holes before implementing.
4. **`seen >= 3` meaningful?** Challenger: raw recurrence is a weak signal Forge used confidence to protect. *Challenger wins;* cheap fix is "distinct sessions on distinct dates," which provenance supplies.

## Critical Issues

1. **Resolve the fact `id` contract — §6 vs §8 contradiction.** *(Decomposer #1, Challenger Pre-Mortem #1)* Most-cited issue; root of the Core Thread. Pin `--id` for facts (or deterministic slug rules + collision behavior) before any downstream op.
2. **Confirm-and-merge must not silently overwrite on id-match.** *(Challenger #1)* id-match ≠ semantic identity. Helper must diff and refuse to overwrite a materially divergent body without surfacing it; Explorer's git-conflict-marker pattern (`<!-- relay:conflict -->` + `relay knowledge resolve`) is the clean implementation.
3. **Facts cap reintroduces silent-partial-continuity the sibling spec eliminated.** *(Challenger Verdict #3)* Surface "N facts not shown — may include load-bearing truths," or honestly downgrade the "agent just knows what's true" goal.
4. **index.md is a SPOF that capped load actively hides.** *(Decomposer + Challenger)* Make it a derived cache full-rebuilt from entry files every locked op; pin the rebuild glob to exclude `graduated/`/`superseded/`.
5. **Graduation leaks local-only learning into a committed file with no retirement path.** *(Challenger #2 + Scope/Demo Risk)* Three holes: uncapped native-load surface (correct the "budget control" claim); no ungraduate/supersede path; commits gitignored local learning into shared instructions (a §2 violation). `RELAY_AUTO_GRADUATE` is a loaded gun. Close all three or scope graduation out of v1.
6. **Replace bare `seen >= 3`** with "distinct sessions on distinct dates" — a weak gate currently guards a behavior-changing write.

## High-Value Enhancements

1. **Helper-stamped `provenance` field — the keystone enhancement.** *(Explorer #1)* `source: history/<date>.md#session-N` at write time, zero agent cost. Prerequisite for contradiction-handling, supplies the distinct-session data for the better graduation gate, unlocks `relay knowledge why`. No Challenger risk. Ship this first.
2. **`confirmed: N` counter on facts** *(Explorer #2)* — free confidence proxy; nudge ranks by `last_confirmed × confirmed_count`. Mitigates Critical Issue #3.
3. **`--near` dedup prompt at write** *(Explorer cross-domain #2)* — helper greps existing fact bodies, shows top-3 candidate ids before commit. Attacks Critical Issues #1/#2; makes "list-before-add" a first-class behavior.
4. **DNS-TTL lazy revalidation** *(Explorer cross-domain #1, "strongest fit")* — optional agent-set `ttl`; read is the revalidation trigger, no daemon. Answers the "staleness needs something to fire" scope risk. Caveat: BSD-vs-GNU `date` portability.
5. **`graduated_to:` back-pointer** *(Explorer #3)* — drift detection when a human deletes the CLAUDE.md line; partial fix for the missing retirement path.

Lower-priority, cheap, no risk: the "bumped to seen:3 — graduation-ready" save-time feedback moment; `relay knowledge export` as a manual gated shared-mode artifact.

## Structural Recommendations

1. **Build index.md as a derived cache first — the implementation keystone.** *(Decomposer)* Sequence: index contract → fact id contract → `add` → load → `graduate` → `supersede`/`prune`. Index schema must carry every rank field (`last_confirmed` for facts, `seen` for lessons) or the O(index) load claim breaks.
2. **Pin graduation atomicity:** idempotent instruction-block write keyed on lesson id → status flip + move → index rebuild, so crash-retry converges and never double-injects. The marked-block edit needs a 4-case test matrix (no block / exists / has-this-id / malformed markers).
3. **Pin date-math portability now** — BSD `date -j -f`, not GNU `date -d`. Affects staleness nudge, `prune`, TTL.
4. **Pin deterministic slug derivation rules** — case-fold, space→dash, punctuation strip, length cap, collision behavior.
5. **Accept the one unfixable-in-bash residue:** dedup depends on the agent reusing a stable id across sessions and across two harnesses (CC + Codex). Mitigate via `--near` + list-before-add; correct §11's "all deterministic" to acknowledge the create/merge/overwrite outcome is agent-determined.

**Bottom line:** all three agents independently conclude the architecture is sound and implementable in deterministic bash 3.2 — fragility is concentrated in two places (the fact `id` contract and index.md consistency), not pervasive. Fix those structurally, resolve the facts-cap contradiction at the spec level, and close the graduation holes, and the design is ready.

---

## Raw Agent Outputs

### Challenger — Adversarial Review

**Pre-Mortem.** (1) Slug-collision AND slug-divergence both corrupt the store — CRITICAL. Divergence (flagged): different slugs for the same fact → duplicates. Collision (NOT flagged): two semantically different facts get the same slug → confirm-and-merge silently overwrites the first. The design treats id-match as proof of semantic identity; it isn't — the same destructive-overwrite class precondition-validation exists to catch, on the happy path. (2) The graduation block grows unbounded and is never reconciled — HIGH. §7 calls graduation "budget control," but CLAUDE.md/AGENTS.md is loaded natively every session and is NOT under RELAY_*_CAP — graduation moves load to an uncapped surface and relabels it solved; no decay, no supersede path for graduated text, no dedup. (3) The "what's true about this repo" answer goes confidently-partial — CRITICAL. The full-day-load spec established silent partial continuity as the worst failure; the facts cap reintroduces exactly that, and both ship in the same cmd_load.

**Assumption Audit.** Three LLM judgments per capture in a determinism tool; the spec relocates semantic identity onto the LLM and calls it deterministic (category error). Confirm-and-merge assumes same-id = confirmation, but it could be a contradiction — last_confirmed gets bumped on a body just overwritten with the opposite claim. seen>=3 with no confidence/decay: a coincidence graduates identically to a real pattern. "Load reads only index.md to rank" but the index may lack a field a ranker needs. "No separate database" is false — index.md is a derived denormalization that desyncs on any missed update.

**Scope Risk.** No cron, but staleness needs something to fire — the gated prune competes with the headline for attention and is the easiest line to ignore forever; the architecture can't drain facts without human action it can't compel. §11 "all deterministic" overstates — the create/merge/overwrite outcome is agent-determined. Graduation leaks gitignored local learning into a normally-committed CLAUDE.md — a §2 hole; a teammate's agent behavior changes from an instruction they never saw graduate.

**Demo Risk.** "Ask the agent what's true and it just knows" breaks the first time a fact sits below the cap; since facts only grow, the probability the asked-about fact is truncated rises monotonically — the demo gets worse with tenure. Duplicate facts visibly appear (slug stability fails across two harnesses). A transient workaround graduates after 3 coincidental hits and persists after the cause is fixed — more dangerous than a stale fact. RELAY_AUTO_GRADUATE is a loaded gun.

**Critical Verdict.** (1) Fix the identity model first — the slug can't be both merge key and unverified judgment; show the agent the existing body, require explicit match/contradiction/distinct, content-hash to catch collisions. (2) Close the graduation-surface hole — retirement path, correct the budget-control claim, reconcile the local-only leak or scope graduation out. (3) Resolve the facts-cap-vs-continuity contradiction directly. Secondary: replace bare seen>=3; prove the index carries every rank field.

### Explorer — Creative Enhancement

**High-Value Additions.** (1) Helper-stamped `provenance` (`source: history/<date>.md#session-N`) — zero agent cost, the cheapest input to contradiction-handling. (2) `confirmed: N` counter on facts mirroring lessons' `seen` — free confidence proxy; rank by `last_confirmed × confirmed_count`. (3) `graduated_to:` back-pointer so `list` detects drift when a human deletes the CLAUDE.md line.

**One-Step-Away.** `relay knowledge why <id>` (cat entry + source handoff section = trust primitive); Lesson→Fact reclassify (same file-move primitive); per-repo `RELAY_GRADUATE_AT` as committed `.relay/config`.

**Experiential Differentiators.** "Bumped to seen:3 — graduation-ready" at save = the self-learning promise made visible; a two-line "what this repo knows about itself" load header; `relay knowledge export > knowledge-pack.md`.

**Cross-Domain Inspiration (§8 focus).** (1) DNS TTL / cache lazy revalidation — strongest fit; agent-set `ttl`, the read is the revalidation trigger, no daemon. (2) Package-manager lockfile resolver — `--near` greps existing bodies, shows top-3 candidate ids before commit. (3) Git conflict markers — body-diff on id-match → `<!-- relay:conflict -->` block + `relay knowledge resolve`. (4) Spaced-repetition signal (not the math) — a `volatility` flag set by whether an entry was ever superseded.

**Enhancement Verdict.** provenance + confirmed-counter + `--near` is one coherent move that dismantles all three §8 open concerns; if only one ships, provenance.

### Decomposer — Structural Analysis

**Component Dependency Graph.** index.md sits on both the write path (every mutating op updates it) and the read path (load reads it exclusively) — the structural keystone and the single point where drift becomes invisible.

**Interface/Contract Gaps.** (1) Fact `id` contract is undefined AND a §6-vs-§8 contradiction (`add --fact` has no `--id`; merge keys on id). (2) Slug derivation/collision unspecified. (3) index↔files consistency asserted, not specified — incremental edit re-creates the surgical-edit corruption per-entry files were chosen to avoid; full-rebuild-from-files avoids it. (4) Tombstone-vs-index timing on graduate/supersede unspecified. (5) Ranking inputs: facts need last_confirmed, lessons need seen; the single `last:` field is insufficient. (6) Date math: GNU `date -d` not on macOS; BSD `date -j -f` is.

**Implementation Sequence.** 1 index.md schema+contract (full-rebuild) → 2 fact id contract → 3 `add` → {4 load, 5 graduate, 6 supersede/prune}.

**Coupling Risks.** index.md SPOF; capped load hides its drift. Rebuild glob must exclude tombstone subdirs (`lessons/*.md` not `**/*.md`). Graduation = 3 mutations, no commit boundary — safe order: idempotent block (keyed on id) → status flip+move → index rebuild. Marked-block edit is the most fragile bash op (4-case test matrix). Agent-judgment coupling on stable ids is the one determinism-boundary leak. No contradiction handling — accretes monotonically.

**Structural Verdict.** Implementable in bash 3.2 but not as specified. Must-fix: resolve fact id contract; make index.md a derived cache; pin graduation ordering+idempotency. Deterministic-but-fragile: date math, marked-block edit. Unfixable-in-bash: dedup depends on the agent reusing stable ids — mitigate via list-before-add. Architecture sound; fragility concentrated in index.md consistency + the fact id contract.

### Synthesizer — Integration

(See the Synthesis section at the top of this document — Core Thread, Tension Map, Critical Issues, High-Value Enhancements, Structural Recommendations.)
