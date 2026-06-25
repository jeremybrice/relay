# Relay — Full Current-Day Load at Session Start: Design Spec

- **Date:** 2026-06-22
- **Status:** Draft — for review before an implementation plan
- **Author:** Jeremy Brice (with Claude)
- **Type:** Enhancement to existing capability — load behavior
- **Relates to:** `design-spec.md` §7 (Load operation), §8 (Rolling-window
  mechanics). Modifies `cmd_load` in `relay.sh`; no schema or save changes.
- **Origin:** Silent partial-continuity failure observed 2026-06-20 in a
  downstream consumer repo (`html-review-tool`), reproduced independently in
  both Claude Code and Codex.

---

## 1. Problem

The load operation (`cmd_load`) injects only the **single most recent** handoff
(`latest.md`) plus the **one-line-per-day** index (`index.md`). When a calendar
day holds more than one session, the earlier sessions of that day are invisible
to a fresh agent at startup.

The full per-day detail lives in `history/<date>.md`, but nothing loads it
automatically — and the index makes the gap worse than it first appears. The
parent design has `index.md` carry **one line per day** (the day's most-recent
digest), and `_index_update` actively strips any prior same-day line
(`grep -v "^- $date "`). So on a two-session day, the index shows only session
2's digest; **session 1's digest is not in the index at all** — it survives only
inside `history/<date>.md`.

### Observed failure

On 2026-06-20 a downstream repo had two sessions in one day — a repo review plus
a ~217 MB cleanup (session 1), then a Codex-wiring fix (session 2). At startup
the agent received only session 2. Asked "what did we do today?", it answered
confidently with session 2's work and **omitted session 1 entirely**, surfacing
it only after being told to read the history file.

This is a **silent correctness gap**: the agent cannot tell it is missing
context, so it returns a partial-but-confident answer. The failure reproduced in
both Claude Code and Codex, which locates it in the **shared load behavior**
(`cmd_load`), not in either adapter.

## 2. Goals

Preserve two properties simultaneously:

1. **The most recent session stays the headline** — `latest.md` leads the
   injected context, prominent and unchanged.
2. **The agent is automatically aware of the full current day** — every session
   of today is in context at startup, without the user asking or the agent
   knowing to read a history file.

And one constraint inherited from the parent design:

3. **Respect the existing context budget.** The load path is deliberately
   disciplined about tokens (`RELAY_WORD_CAP`, the truncation `awk`, history
   pruning to 10). The fix must live inside that discipline, not bypass it.

## 3. Decision

**`cmd_load` emits today's earlier same-day sessions in addition to the existing
`latest.md` headline, bounded by the existing word budget, with the fix made in
the shared loader (not the adapters).**

Three load-bearing choices:

### 3.1 Load the full *current day*, not just the latest session

The deciding factor is **asymmetry of failure modes**:

| Direction | Failure mode | Cost |
|---|---|---|
| Latest-only (status quo) | Agent answers "what did we do today" confidently partial | High — silent; the user cannot tell it is incomplete |
| Full current day | A few hundred extra tokens on multi-session days | Low — bounded, visible |

For a tool whose entire purpose is continuity, **silent partial continuity is a
worse failure than a bounded token cost.** The parent design's "headline +
breadcrumbs, agent pulls detail on demand" model is sound in general but breaks
exactly here: the agent does not know it needs to pull, so it never does.

**Day-bounded, not "last N sessions."** A calendar-day window matches how users
think ("what did we do today"), self-resets at midnight, and avoids a
session-count window unpredictably straddling a multi-day gap. `history/<date>.md`
already aggregates exactly one day, most-recent last — the natural unit.

### 3.2 Bound the emit to the existing word budget; drop the duplicate latest

Two refinements over a naïve `cat history/<today>.md`:

- **Respect `RELAY_WORD_CAP`.** A raw `cat` of the day file ignores the cap the
  rest of the load path enforces and reintroduces precisely the bloat the design
  guards against. The today-block must be governed by the same budget, reusing
  the existing truncation pattern, and truncate the **oldest** same-day sessions
  first (they are least relevant to the next agent) with a "…open
  `history/<date>.md` for full detail" pointer.
- **Do not double-emit `latest`.** `latest.md` is already the headline and equals
  the day's most recent session. The today-block emits only the **earlier**
  same-day sessions (all but the last). This keeps the context clean and avoids
  the confusing case where the word-capped `latest.md` and an uncapped history
  copy of the same session both appear.

Net shape of the injected context, in order:
1. Recency line (unchanged).
2. `latest.md` headline — full, soft-capped (unchanged).
3. **New:** today's earlier same-day sessions, budget-bounded, oldest truncated
   first — present only when today has ≥2 sessions.
4. `index.md` verbatim (unchanged).
5. The "open `history/<date>.md` on demand" pointer (unchanged).

### 3.3 Make the change in `cmd_load`, not the adapters

Both adapters call `relay.sh load`, and the Codex path JSON-escapes the same
`out` string before emitting it as `systemMessage`. A single append inside
`cmd_load` therefore flows to **both** harnesses identically and for free.

Placing the fix in `cmd_load` is also the direct antidote to the adapter wiring
drift that produced the original report: keeping load behavior uniform in the
shared core means the two adapters cannot diverge on it. The adapters stay thin
(trigger wiring + injection field only), per the parent design's boundary
invariant.

## 4. Non-goals (out of scope for this change)

- **A digests-only / leaner same-day mode.** The parent design's "optional
  refinement" (headline in full; earlier same-day sessions as one-line digests).
  Rejected for now on two grounds: (a) it is *more* code, and (b) it needs new
  plumbing the budget-bounded full emit does not — per-session digests for the
  current day do not exist, because `_index_update` dedupes the index to one line
  per day, so a digest-capped mode would require `cmd_save`/`_index_update` to
  retain per-session digest lines. The budget-bounded full-day emit (§3.2) solves
  the bloat concern without that plumbing. Revisit only if real usage shows
  genuinely heavy days.
- **"Last N sessions" / multi-day windows.** Rejected in §3.1 — the day is the
  right unit.
- **Any change to the save path, the handoff schema, `index.md`, or rotation.**
  This is a read-side change only.
- **Loading more than the current day at startup.** Prior days remain
  index-line + on-demand, exactly as today.

## 5. Alternatives considered

- **Keep latest-only (status quo).** Lowest token cost; matches the "agent pulls
  detail on demand" philosophy. Rejected: that philosophy fails precisely where
  it matters here — the agent cannot detect the gap, so it answers
  confidently-partial. Silent partial continuity is the worst failure for a
  handoff tool (§3.1).
- **Raw `cat history/<today>.md`** (the origin proposal's primary suggestion).
  Simplest, correct on coverage. Rejected as-is: it ignores `RELAY_WORD_CAP` and
  double-emits the latest session. Adopted in refined form — bounded and
  de-duplicated (§3.2).
- **Digests-only same-day mode.** More code, needs new save-side plumbing; see
  §4.
- **Fix in the adapters instead of the core.** Rejected — duplicates logic across
  two adapters and reintroduces the drift that caused the original report (§3.3).

## 6. Acceptance check

On a day with ≥2 sessions, a fresh session start puts **all** of that day's
session summaries into context — verifiable by asking "what did we do today?" and
getting every session back **without** the agent reading any history file
manually. On a single-session day, the injected context is unchanged from today's
behavior (no empty today-block). On a multi-session day large enough to exceed the
budget, the oldest sessions are truncated with a pointer — the emit never grows
unbounded, and the most recent session is never the one truncated.

## 7. Open questions for review

1. **Budget allocation.** Should the today-block share one combined `RELAY_WORD_CAP`
   with the `latest.md` headline, or carry its own separate cap? A combined cap is
   simpler and bounds total injected context directly; a separate cap guarantees
   the headline is never squeezed by a busy day. (Leaning: separate, modest cap
   for the today-block so the headline is always whole.)
2. **Session ordering within the today-block.** Most-recent-earlier first (closest
   to the headline) vs. chronological. (Leaning: chronological, so reading
   top-to-bottom reconstructs the day's narrative, with the headline as the
   already-seen finale.)
