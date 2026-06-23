# Relay — portable session handoff + learning

Relay gives AI coding agents a memory that survives between sessions, in **any**
repo it lives in. It does two things, side by side:

- **Hands off** — at the end of a session it writes a structured handoff so the
  next session (or the next agent) picks up where you left off.
- **Learns** — it accumulates durable facts and behavioral lessons about working
  in this repo, and lessons that keep recurring can graduate into the repo's
  instruction file as standing rules.

It is **deterministic, daemon-free, local-only, and cross-harness** — one tool
that works the same under Claude Code and Codex, built on a single
zero-dependency bash helper (`relay.sh`).

## Two tiers

| Tier | What it holds | Answers | Lifespan |
| --- | --- | --- | --- |
| **1 · Ephemeral handoffs** | A 6-section handoff per session (Summary / Changed / Decisions / Next / Watch-out / Open questions), a one-line-per-day index, a dated history file. | *"What happened recently?"* | Rolling 10-day window, then pruned. |
| **2 · Durable knowledge** | Facts and lessons captured at the same save moment. | *"What's permanently true, and what have I learned here?"* | Never pruned. |

## How it works — the division of labor

This is Relay's core invariant and what keeps it portable:

- **`relay.sh` (the deterministic core)** owns every write, merge, dedup, counter
  bump, and prune — all under a portable `mkdir` lock. The agent never edits the
  data files directly, which is what makes the counters trustworthy and
  graduation idempotent.
- **The agent** owns judgment and prose: is this durable? does it match an
  existing lesson? what's the stable id? It authors; the helper records.
- **Adapters stay thin** — per harness they wire the trigger (a `SessionStart`
  hook), the context-injection field, and the thin save/learn commands, then call
  the same core. Swap an adapter without touching the core.
- **The data is just markdown** — fully readable with no adapter at all.

## Install (in any repo)

```bash
curl -fsSL https://<host>/relay/install.sh | bash
# or: download install.sh, read it, then `bash install.sh`
```

The installer detects the harness(es) present, lays down `.relay/` (the tool —
committed, travels via git), wires the `SessionStart` hook plus a save command for
each harness, gitignores `.session-log/` (your handoffs and knowledge — local
only), and plants the `<!-- relay:learned -->` anchor in `CLAUDE.md`/`AGENTS.md`.
It is additive and reversible — nothing existing is rewritten.

## Use

- **Load** is automatic: the last handoff, active knowledge, and the index are
  injected at session start. Knowledge loads under its own budget so it can't
  crowd out the handoff, and any truncation is stated explicitly (e.g.
  `⚠ 14 of 31 facts shown`) — never silent.
- **Save** with `/session-save` (Claude Code) or `$session-save` (Codex) — or the
  agent offers when you wrap up. One reflection routes into three destinations:
  the handoff, any new facts, and any new/reinforced lessons.
- **Learn mid-session** with `/relay-learn` (`$relay-learn` on Codex) to capture a
  fact or lesson the moment it comes up.

## Knowledge model — facts vs lessons

The two kinds are not cosmetic: facts are *looked up*, lessons are *acted on* and
can harden into rules.

- **Facts** — reference truths about the repo (e.g. *"deploys ship via
  `scripts/release.sh`, never `npm publish`"*). Carry a `confirmed` counter
  (reinforcement proxy) and an optional `ttl` for freshness. On a divergent
  rewrite they raise a **conflict** rather than silently overwriting — you pick a
  side with `resolve --keep new|existing` (defaults to keeping the existing fact).
  Facts **never graduate**.
- **Lessons** — behavioral patterns (*when X → prefer Y, because Z*). Carry a
  `seen` count plus a `sessions` count of **distinct dates**. Lessons can
  graduate.

## Lesson lifecycle

A lesson advances by a counter and a threshold, ending in a gated append — no
confidence math, no decay scheduler:

1. **Noticed** — captured at save (`sessions: 1`).
2. **Reinforced** — re-asserted on a *new day*; same-day repeats don't count, so a
   coincidence seen three times in one afternoon can't masquerade as a pattern.
3. **Ready** — at `sessions ≥ 3` (configurable via `RELAY_GRADUATE_AT`).
4. **Graduated** — the agent **proposes**, you approve, and the lesson is written
   as an id-keyed block into `CLAUDE.md`/`AGENTS.md` where the harness loads it
   natively. This step is always gated — it's a persistent, behavior-changing
   edit to a file you may commit.

A graduated rule that goes stale is drained with `knowledge ungraduate <id>`; a
wrong lesson or fact is retired with `knowledge supersede <id>`. Nothing is ever
silently orphaned.

## Command surface

Every write is a `relay.sh` subcommand:

```bash
relay knowledge add --fact   --near "…"          # show matching ids, write nothing
relay knowledge add --fact   --id <slug> "…"     # create / confirm / or raise conflict
relay knowledge add --lesson --id <slug> "…"     # create / bump seen + sessions
relay knowledge graduate <id>                    # write a reinforced lesson into the
                                                 #   instruction file (gated)
```

Curation verbs round out the surface — `resolve --keep new|existing` (settle a
conflict), `supersede <id>` (retire an entry), `prune --yes` (retire stale facts),
`ungraduate <id>`, `why <id>` (show provenance), `list`, and `export`. See the
design walkthrough for the full reference.

## What it deliberately isn't

Relay keeps the *idea* of a learning system — capture → reinforce → graduate — and
drops the machinery a dogfood repo won't have:

- No cron, background capture, or batch analyzer.
- No time-decay (no scheduler to run it) — staleness is handled by lazy TTL checks
  at load and by deliberate `supersede`.
- No confidence-score math — just the `seen`/`sessions` counter and a threshold.
- No committed/shared or cross-repo store yet (the config switch is reserved). The
  one thing that travels today is a *graduated* lesson, because the instruction
  file is yours to commit.

## Layout

```
.relay/              committed · the tool travels via git
  relay.sh           the deterministic core (load · save · knowledge …)
  adapters/          templates the installer wires from

.session-log/        git-ignored · local-only
  latest.md          newest single-session handoff
  index.md           one line per day, ≤ 10 days
  history/           one file per day, last 10 (older pruned)
  knowledge/         durable, never pruned
    index.md         derived cache — rebuilt from entry files every locked op
    facts/<id>.md    one file per fact   (+ superseded/ tombstones)
    lessons/<id>.md  one file per lesson (+ graduated/, superseded/)

CLAUDE.md / AGENTS.md  gains a <!-- relay:learned --> block for graduated lessons
```

Full design walkthrough:
[`docs/relay-learning-design.html`](docs/relay-learning-design.html) — this README
is a distilled subset. Design spec and review history live under `docs/`.
