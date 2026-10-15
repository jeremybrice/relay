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

From the root of the repo you want Relay in:

```bash
curl -fsSL https://raw.githubusercontent.com/jeremybrice/relay/main/dist/install.sh | bash
```

Pass flags after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/jeremybrice/relay/main/dist/install.sh | bash -s -- --clis claude,cursor   # no prompt
curl -fsSL https://raw.githubusercontent.com/jeremybrice/relay/main/dist/install.sh | bash -s -- --detect              # only CLIs already present
```

Or download it, read it, then run it: `curl -fsSLO https://raw.githubusercontent.com/jeremybrice/relay/main/dist/install.sh && bash install.sh`.

With a local clone of this repo, run the source installer instead (same flags):

```bash
bash ~/Documents/GitHub/relay/install.sh
```

The installer asks which CLIs to set up (Claude Code, Codex, OpenCode, Cursor, Grok Build),
with any already present in the repo pre-checked. Toggle by number, `a` for all,
Enter to finish. Without a terminal it falls back to `--detect`. It then lays down
`.relay/` (the tool — committed, travels via git), wires a session-start load plus
save commands for each chosen CLI, gitignores `.session-log/` (your handoffs and
knowledge — local only), and appends one labeled block per CLI to `AGENTS.md`
(Claude Code reads it too). It is additive, idempotent, and reversible — nothing
existing is rewritten. Re-installing over an older install moves Claude Code's block
out of `CLAUDE.md` into `AGENTS.md`, leaving the rest of `CLAUDE.md` untouched.

Each block also tells the agent that the handoff and index are summaries: when the
task touches work from an earlier day, it should open that day's
`.session-log/history/<date>.md` before starting.

| CLI | Load at session start | Save / learn / compact |
|-----|-----------------------|------------------------|
| Claude Code | `SessionStart` hook in `.claude/settings.json` + `AGENTS.md` block | `.claude/skills/` → `/session-save`, `/relay-learn`, `/relay-compact` |
| Codex | `SessionStart` hook in `.codex/config.toml` + `AGENTS.md` fallback | `.codex/skills/` → `$session-save`, `$relay-learn`, `$relay-compact` |
| OpenCode | `instructions` snapshot in `opencode.json` | `.opencode/commands/` → `/session-save`, `/relay-learn`, `/relay-compact` |
| Cursor | `AGENTS.md` block (reads `.session-log/latest.md` + `index.md`) | `.cursor/skills/` → `session-save`, `relay-learn`, `relay-compact` |
| Grok Build | `.grok/hooks/relay.json` (run `/hooks-trust` once) + `AGENTS.md` block | `.grok/skills/` → `session-save`, `relay-learn`, `relay-compact` |

Claude Code, Cursor, and Grok share one skill set (`adapters/skills/`). Every
install also ships `.relay/tests/smoke-compact.sh`, the contract test for
`knowledge compact` / `restore`.

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
   as an id-keyed block into `AGENTS.md` (or `CLAUDE.md`, if it already holds
   graduated rules) where the harness loads it
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

AGENTS.md              gains a <!-- relay:learned --> block for graduated lessons
```

Full design walkthrough:
[`docs/relay-learning-design.html`](docs/relay-learning-design.html) — this README
is a distilled subset. Design spec and review history live under `docs/`.
