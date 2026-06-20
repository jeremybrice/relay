# Relay — Portable Session Handoff: Design Spec

- **Date:** 2026-06-19 (revised 2026-06-20)
- **Status:** Draft — final review before the implementation plan
- **Author:** Jeremy Brice (with Claude)
- **Type:** New capability — portable, cross-harness, local-only
- **Relates to:** Extraction of the generic handoff core from the Forge
  session-lifecycle system (`hooks/session-start.sh` `session_state` block,
  `.forge/session-log/`, `/session-save`). Strategic wedge for a later
  learning-system export — that larger effort is **out of scope** here.

---

## 1. Problem

An agent starting a fresh session in a repo has no memory of what the last
session did. Work restarts cold: the agent re-derives context, re-discovers where
things were left, and often asks "what were we working on?" instead of continuing.

The Forge workspace already solves this for itself — a daily handoff file, a
rolling 10-day history, and a SessionStart hook that auto-loads the last handoff.
But that implementation is welded to Forge (it loads Forge tasks, taxonomy,
initiatives, review queues, and mines org-memory on save). None of that transfers.

**Relay** extracts the generic handoff core and makes it portable: drop it into
any repo — yours, a teammate's, a non-Forge codebase — and agents hand off to each
other day to day across a rolling 10-day window, regardless of whether the agent
runs in Claude Code or Codex, with the handoff data kept strictly local to that repo.

## 2. Goals

- A fresh agent session **orients from the last handoff automatically**.
- Continuity across a **rolling 10-day window**: full last session + cheap
  awareness of prior days, detail on demand.
- **Portable across Claude Code and Codex** via a harness-agnostic core + thin adapters.
- **Installable into any repo** with one idempotent command.
- **Reliable under multiple agents** working the same repo — multi-*agent*, not
  multi-device — via file locking.
- Handoffs are **substantive, not placeholder**.
- **Local to each repo:** handoff data never leaves the machine.

## 3. Non-goals (explicitly out of scope for v1)

- The larger learning-system export (observation capture, instinct distillation,
  promotion). Relay is the distribution wedge for it, not that system.
- **Hook-automatic save (L3)** — a `SessionEnd`/`Stop` agent-hook that writes the
  handoff with no user or agent action. Deferred to v2 (needs a viability spike).
  v1 triggers are **L1 + L2 only** (§6).
- **Multi-device / cloud sync of handoff data.** Relay is deliberately local-only
  and per-repo (§11).
- The Forge-specific load sources (tasks, taxonomy, initiatives, reviews) and the
  org-memory mining in `/session-save`.
- Hook profiles (`minimal` / `standard` / `strict`). Relay has one behavior.
- An adapter for harnesses beyond Claude Code and Codex.
- Crash-recovery `git diff` auto-stub for hard kills (§17, v2).

## 4. Architecture — three units + a deterministic helper

```
┌──────────────────────────────────────────────────────────────────┐
│ Installer   detect harness(es) · lay down Core · wire Adapter(s)   │
└──────────────────────────────────────────────────────────────────┘
                              │
     ┌────────────────────────┴───────────────────────┐
     ▼                                                 ▼
┌──────────────────┐                       ┌────────────────────────────┐
│ Adapter (CC)     │   Adapter (Codex)     │ Core                       │
│ SessionStart hook │  SessionStart hook    │  relay.sh  (load/save/     │
│ + /session-save   │  + $session-save      │            rotate/prune/   │
│                   │                       │            lock)           │
└──────────────────┘                       │  .session-log/ (data)      │
                                            └────────────────────────────┘
```

- **Core** *(harness-agnostic)* — the `.session-log/` data folder plus a
  **deterministic helper script `relay.sh`** that performs *every* file operation
  (load, save, rotate, prune) under a lock. The Core knows nothing about Claude
  Code or Codex.
- **Adapters** *(thin, per-harness)* — wire the Core's two operations
  (`relay load`, `relay save`) into a harness's native trigger points. Two ship
  in v1: Claude Code and Codex.
- **Installer** — a single embedded `install.sh` (§12) that detects the
  harness(es), lays down the Core, copies the adapter(s), wires them, and
  gitignores the data.

**Division of labor (the load-bearing principle):** the agent *only* authors the
six sections + a one-line digest. Every byte-level operation — write, append,
rotate, prune, and the lock — is done by `relay.sh` deterministically.
Pruning-to-10 and correct appends are never left to LLM judgment. This makes the
behavior testable and the lock enforceable.

**Boundary invariant:** an Adapter can be swapped without touching the Core, and
the data is fully readable with no Adapter at all (it is just markdown).

## 5. Core — layout & file schema

```
.relay/                  # the TOOL — committed (travels via git to other repos/people)
  relay.sh               # deterministic helper: load | save | rotate | prune | lock
  adapters/              # adapter templates the installer wires from

.session-log/            # the DATA — gitignored, local-only, per-repo (§11)
  latest.md              # newest single-session handoff (frontmatter + 6 sections)
  index.md               # one line per day, ≤10 days
  .lock                  # advisory lock file (flock)
  history/
    2026-06-20.md        # one file per calendar day; same-day sessions appended
    …                    # last 10 dated files; older pruned
```

A handoff is YAML frontmatter (carried in `latest.md` too) plus six fixed sections:

```markdown
---
date: 2026-06-20
session: 2          # nth session on this date
digest: "Extracted handoff core; chose deterministic script + locking"
---

## Summary        # 2–3 sentences: what this session set out to do, how far it got
## Changed        # files / areas touched, with paths — the "where to look" map
## Decisions      # choices made + one-line rationale each
## Next           # explicit, ordered next steps — the most load-bearing section
## Watch out      # blockers, gotchas, half-finished edges
## Open questions # unresolved threads for the next agent
```

`index.md` carries **one line per day** (the day's most-recent digest); there is
no separate index database to keep in sync:

```markdown
# Session index — last 10 days
- 2026-06-20 — Extracted handoff core; chose deterministic script + locking → history/2026-06-20.md
- 2026-06-19 — …
```

## 6. Save operation

### Triggering (v1 = L1 + L2)

The save is agent-invoked, two ways:

- **L1 — Explicit.** The user runs `/session-save` (Claude Code) or `$session-save`
  (Codex). Highest fidelity — the agent writes from full in-context memory.
- **L2 — Agent-prompted.** The adapter instructs the agent to *offer* a save (one
  line) on ambiguous wrap-up cues, and to save outright on an explicit signal
  ("done for today" / "let's continue tomorrow").

Hook-automatic save (L3) is deferred to v2 (§3, §17). v1 reliability rests on
L1 + L2: if neither fires before a hard exit, that one session's handoff is lost.

### Behavior (deterministic, via `relay save`)

The agent authors the six sections + the digest, then calls `relay save`. The
script, **holding the lock** (§10):

1. Append to `history/<today>.md` after a `## Session N` separator
   (N = existing sessions + 1), or create it as session 1.
2. Overwrite `latest.md` with **this session's** handoff (not the whole day).
3. Update **today's** line in `index.md` (replace it if present, else prepend);
   keep ≤10 day-lines.
4. Prune `history/` to the **10 most-recent dated files**.

Best-effort: a missing `.session-log/` is created on the fly; the save never
fails the session.

## 7. Load operation (automatic at session start)

Both adapters fire a SessionStart hook that calls `relay load`, which emits:

- A **recency line** — `Last saved: 2026-06-20 (today)`, or a ⚠ flag when
  `latest.md` is older than ~3 days (`⚠ Last saved 2026-06-11 — 9 days ago`).
  This satisfies the `outcome-validation-hooks` staleness scenario.
- **`latest.md` in full**, soft-capped at ~800 words (a truncation note appended
  if the cap is hit).
- **`index.md` verbatim** — the dated ≤10-day map.
- A one-line note that the agent may open any `history/<date>.md` on demand.

Load **never blocks** session start; missing files are skipped silently.

## 8. Rolling-window mechanics

- The unit is the **dated daily file**; the window is the **10 most-recent dated
  files** — calendar gaps (weekends) do not shrink it.
- The 11th distinct day prunes the oldest file and its `index.md` line.
- Same-day sessions **append** to that day's file; `latest.md` reflects the most
  recent single session; `index.md` holds exactly one line for the day.

## 9. Cross-harness adapters (symmetric)

Both adapters call the same `relay.sh`; only the trigger wiring and the
context-injection field differ.

| Operation | Claude Code | Codex |
|---|---|---|
| **Load** | `SessionStart` hook → `relay load`; output injected via `additionalContext` | `SessionStart` hook → `relay load`; output injected via `systemMessage` |
| **Save L1** | `/session-save` command → `relay save` | `$session-save` skill → `relay save` |
| **Save L2** | agent-prompt instruction (CLAUDE.md / skill) | agent-prompt instruction (AGENTS.md) |
| **Hook config** | `.claude/settings.json` | `.codex/config.toml` `[hooks]` |

Verified against Codex's official docs: Codex has a real `SessionStart` hook (can
inject via `systemMessage`), first-class `$`-invoked skills, and `config.toml`
hooks. **Residual smoke-test (build-time):** confirm Codex's `systemMessage`
reaches *model* context, not just the UI; if it doesn't, Codex's auto-injected
`AGENTS.md` instruction-chain is the guaranteed fallback for load.

## 10. Concurrency & locking

For multiple agents working the same repo simultaneously:

- `relay.sh` wraps its **file-mutation critical section** in an advisory lock
  (`flock` on `.session-log/.lock`).
- **Authoring happens before the lock.** The lock covers only the brief
  write/rotate/prune, so a concurrent saver waits only for that — not for the
  other agent's thinking.
- **Wait-your-turn:** the first saver acquires the lock; a concurrent saver
  blocks until release, then proceeds.
- `flock` releases automatically when the holding process exits, so a crashed
  agent cannot wedge the lock (no stale-lock cleanup needed). A bounded wait
  (`flock -w <seconds>`) prevents an indefinite block.

## 11. Storage & git

- **`.session-log/` (the data) is gitignored, local-only, per-repo.** The
  installer adds it to `.gitignore`. Handoffs never go to git or any cloud.
- **The Relay tool (`.relay/`, adapter hooks/skills, config wiring) IS committed**
  — that is how the tool travels to other repos and people; each environment then
  generates its own local handoffs.
- Git worktrees each get their own `.session-log/` (local to that working dir).
- **Forward note (v2):** handoffs are designed to later reconcile against each
  agent's own local action-memories — keeping the data local serves that future
  alignment.

## 12. Installer & distribution

### The transfer package

The deliverable is a **single self-contained `install.sh`** — the canonical
`relay.sh` and the adapter templates are embedded inside it as heredocs, so it is
one file with no external fetch at install time.

- **Source vs deliverable:** Relay develops in its own small git repo (readable
  `relay.sh`, adapter templates, tests). A release step concatenates those sources
  into the bundled `install.sh`; that bundled file is the artifact you share.
- **How it travels:** run `curl -fsSL <url>/install.sh | bash` from the target
  repo's root, **or** hand someone the file to read and run with `bash install.sh`
  — offline / air-gapped friendly, and readable before running (no blind
  `curl | bash` trust required).
- **Updates:** re-run the installer; it is idempotent.
- **Not in v1:** no npm/Node wrapper and no Claude Code plugin channel (both are
  v2 conveniences — §17). One harness-neutral artifact serves both harnesses.

### Install behavior

A bash `install.sh`:

1. **Detect** `.claude/` and/or `.codex/`. If **both** are present, install
   **both** adapters over one shared Core. If neither, ask the user or skip.
2. **Lay down** `.relay/` (the tool) and the `.session-log/` skeleton (data).
3. **Wire** — CC hook into `.claude/settings.json`; Codex hook into
   `.codex/config.toml`. Both are committed.
4. **Gitignore** `.session-log/`.

Discipline, per existing repo rules: **idempotent** (checks its own marker before
appending; running twice produces no duplicate wiring) and **precondition-gated**
(skips cleanly with a message if no harness is detected). Windows requires Git
Bash / WSL for the bash script — a noted v1 limitation.

## 13. Error handling

- **Load** never blocks; absent files are skipped; the stale flag is surfaced, not fatal.
- **Save** self-heals a missing directory; lock contention waits (bounded by `-w`);
  never throws into the session.
- **Prune** is best-effort; a failure leaves extra history rather than crashing.
- **Install** is reversible (additive files + a marked config block) and refuses
  to half-wire.

## 14. Testing strategy

- **Lifecycle (script)** — 11 days of `relay save` → `history/` caps at 10 files,
  `index.md` = 10 day-lines, oldest pruned, `latest.md` = newest, and a same-day
  re-save **replaces** the day's index line (no duplicate).
- **Concurrency** — two `relay save` runs in parallel → both complete, no clobber,
  serialized by the lock.
- **Orientation** (`outcome-validation-hooks`) — a filled handoff clears ≥1 named
  file/path, ≥1 dated fact, ≥1 real entity, ≥100 words of body.
- **Staleness** — `relay load` on a 9-day-old `latest.md` surfaces the ⚠ flag.
- **Idempotency** — installer twice → no duplicate wiring.
- **Trigger-wiring** — each adapter carries L1 (skill/command → `relay save`) and
  the L2 agent-prompt instruction.
- **Codex smoke-test** — SessionStart `systemMessage` reaches model context; else
  the AGENTS.md fallback is exercised.

## 15. Naming

Working name **Relay** (agents relay the baton). Data dir `.session-log/`, tool
dir `.relay/` — descriptive and brand-neutral. Alternates: *Baton, Carryover,
Handoff*. Cosmetic; renamable before release.

## 16. Alternatives considered

- **Loading model** — *last-session-only* (ignores the 10-day intent) and *full
  10-day digest* (token tax every session) rejected in favor of **full last
  session + surfaced index**.
- **Handoff schema** — a *lean 3-part* form risked placeholder handoffs; the *full
  Forge log* is too heavy. Chose the **6-section structured** form.
- **Packaging** — a *Claude-Code-only plugin* fails cross-harness; a *pure copy-in
  convention* has no enforcement. Chose the **portable core + thin adapters**.
- **File operations** — *agent-executed* (LLM does the writes/pruning) rejected in
  favor of a **deterministic `relay.sh` script**: reliability, testability, and
  the lock all require it.
- **Storage** — *committed / cloud-synced* rejected in favor of **local-only,
  gitignored** data: it is multi-*agent*, not multi-device, and the data must stay
  local to reconcile with agents' local action-memories later.
- **Distribution** — a *thin fetch-installer* (needs network, not one-file) and a
  *Claude-Code plugin* (CC-only, duplicates the installer) rejected in favor of a
  **single embedded `install.sh`**: harness-neutral, offline-capable, one file to share.

## 17. Future (v2+)

- **L3 hook-automatic save** — a `SessionEnd` (CC) / `Stop` (Codex) agent-hook
  reads the session `transcript_path` and writes the handoff when L1/L2 didn't
  fire. Both harnesses expose such an end-hook; pending a viability spike
  (teardown timing; agent-hooks are framed for verification).
- **`PreCompact` checkpoint** — write a handoff before context compaction on long sessions.
- **`git diff` crash-recovery stub** — for the hard-kill case L3 can't catch.
- **Reconcile handoffs against each agent's local action-memories.**
- **`relay digest`** — a single rolled-up brief across the full 10-day window on demand.
- **A generic / instruction-only adapter** for harnesses beyond Claude Code and Codex.
- **A Claude Code plugin wrapper** (and/or an `npx` channel) as convenience installers.
- **The larger learning-system export** riding the same installer/adapter layer.
