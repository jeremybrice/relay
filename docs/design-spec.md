# Relay: Portable Session Handoff, Design Spec

- **Date:** 2026-06-19 (revised 2026-06-20; synced to the shipped code 2026-10-16)
- **Status:** Implemented. This spec describes the handoff tier as it ships today.
- **Author:** Jeremy Brice (with Claude)
- **Type:** Portable, cross-harness, local-only capability
- **Relates to:** Extraction of the generic handoff core from the Forge
  session-lifecycle system (`hooks/session-start.sh` `session_state` block,
  `.forge/session-log/`, `/session-save`). The durable knowledge tier (facts,
  lessons, graduation) shipped on top of this core and is documented in
  [`relay-learning-design.html`](relay-learning-design.html).

---

## 1. Problem

An agent starting a fresh session in a repo has no memory of what the last
session did. Work restarts cold: the agent re-derives context, re-discovers where
things were left, and often asks "what were we working on?" instead of continuing.

The Forge workspace already solved this for itself with a daily handoff file, a
rolling 10-day history, and a SessionStart hook that auto-loads the last handoff.
That implementation is welded to Forge (Forge tasks, taxonomy, initiatives,
review queues, org-memory mining on save). None of that transfers.

**Relay** extracts the generic handoff core and makes it portable: drop it into
any repo and agents hand off to each other day to day across a rolling 10-day
window, whichever CLI they run in, with the handoff data kept strictly local to
that repo.

## 2. Goals

- A fresh agent session **orients from the last handoff automatically**.
- Continuity across a **rolling 10-day window**: full last session plus cheap
  awareness of prior days, detail on demand.
- **Portable across CLIs** via a harness-agnostic core and thin adapters. Five
  ship today: Claude Code, Codex, OpenCode, Cursor, Grok Build.
- **Installable into any repo** with one idempotent command, which is also the
  update path.
- **Reliable under multiple agents** working the same repo (multi-agent, not
  multi-device) via a lock.
- Handoffs are **substantive, not placeholder**.
- **Local to each repo:** handoff data never leaves the machine.

## 3. Non-goals

- **Hook-automatic save (L3):** a `SessionEnd` / `Stop` hook that writes the
  handoff with no user or agent action. Deferred (needs a viability spike).
  Saves are **L1 + L2 only** (§6).
- **Multi-device or cloud sync of handoff data.** Relay is deliberately
  local-only and per-repo (§11).
- The Forge-specific load sources (tasks, taxonomy, initiatives, reviews) and the
  org-memory mining in Forge's `/session-save`.
- Hook profiles (`minimal` / `standard` / `strict`). Relay has one behavior.
- Crash-recovery `git diff` auto-stub for hard kills (§17).
- Native Windows. The scripts need Git Bash or WSL.

## 4. Architecture: installer, adapters, core

```
┌─────────────────────────────────────────────────────────────────────┐
│ Installer  pick CLIs · lay down .relay/ · wire adapters · gitignore │
└─────────────────────────────────────────────────────────────────────┘
                                  │
   ┌──────────────┬──────────────┼──────────────┬──────────────┐
   ▼              ▼              ▼              ▼              ▼
 Claude Code    Codex          OpenCode       Cursor         Grok Build
 hook+skills    hook+skills    snapshot+cmds  AGENTS+skills  hook+skills
   └──────────────┴──────────────┼──────────────┴──────────────┘
                                  ▼
            ┌───────────────────────────────────────────┐
            │ Core: .relay/relay.sh                     │
            │   load · save · knowledge …  (one lock)   │
            │ Data: .session-log/  (plain markdown)     │
            └───────────────────────────────────────────┘
```

- **Core** (harness-agnostic): the `.session-log/` data folder plus the
  deterministic helper `relay.sh`, which performs every file operation (append,
  overwrite, index rebuild, prune) under a lock. The core knows nothing about
  any CLI.
- **Adapters** (thin, per CLI): wire `relay load` into the CLI's session-start
  surface and expose `session-save`, `relay-learn`, and `relay-compact` as that
  CLI's commands or skills. Each adapter also adds one labeled block to
  `AGENTS.md`.
- **Installer:** `install.sh` asks which CLIs to wire, lays down the core,
  copies and wires the adapters, and gitignores the data (§12).

**Division of labor (the load-bearing principle):** the agent only authors the
six sections and a one-line digest. Every byte-level operation is done by
`relay.sh` deterministically. Pruning to 10 and correct appends are never left
to LLM judgment, which makes the behavior testable and the lock enforceable.

**Boundary invariant:** an adapter can be swapped without touching the core, and
the data is fully readable with no adapter at all (it is just markdown).

## 5. Core: layout and file schema

```
.relay/                    # the TOOL, committed (travels via git)
  relay.sh                 # deterministic helper: load | save | knowledge …
  adapters/                # templates the installer wires from
  tests/smoke-compact.sh   # contract test for knowledge compact / restore

.session-log/              # the DATA, gitignored, local-only, per-repo (§11)
  latest.md                # newest single-session handoff (frontmatter + 6 sections)
  index.md                 # Markdown table, one row per day, ≤ 10 days
  .relay-format            # data layout version (2); see below
  .lock/                   # present only while a write holds the lock (§10)
  relay-instructions.md    # OpenCode only: load snapshot refreshed on save
  history/
    2026-06-20.md          # one file per calendar day; same-day sessions appended
    …                      # 10 most recent dated files; older pruned
  knowledge/               # durable tier, never pruned (see the learning design)
```

`.relay-format` holds the data layout version (currently `2`, table indexes).
Every locked write stamps it when it is missing, unreadable, or older. If it
names a newer version than the running `relay.sh`, every locked write refuses
(exit 1, pointing at `install.sh --detect`) and load prepends a warning, so an
out-of-date copy of the tool can never rewrite a newer store.

A handoff is YAML frontmatter (written by `relay.sh`, carried in `latest.md` too)
plus six fixed sections authored by the agent:

```markdown
---
date: 2026-06-20
session: 2          # nth session on this date
digest: "Extracted handoff core; chose deterministic script + locking"
---

## Summary        # 2 to 3 sentences: what this session set out to do, how far it got
## Changed        # files and areas touched, with paths: the "where to look" map
## Decisions      # choices made, one-line rationale each
## Next           # explicit, ordered next steps: the most load-bearing section
## Watch out      # blockers, gotchas, half-finished edges
## Open questions # unresolved threads for the next agent
```

`index.md` is a table with **one row per day** (that day's most recent digest),
newest first, columns padded so it reads cleanly raw or rendered. Pipes, tabs,
and line breaks in a digest are flattened in the index only; the history file
keeps the original. There is no separate database to keep in sync:

```markdown
# Session index (last 10 days)

| Date       | Summary                                                      | History                             |
|------------|--------------------------------------------------------------|-------------------------------------|
| 2026-06-20 | Extracted handoff core; chose deterministic script + locking | [2026-06-20](history/2026-06-20.md) |
| 2026-06-19 | …                                                            | [2026-06-19](history/2026-06-19.md) |
```

A legacy line-format index (`- date — digest → history/date.md`) is read and
migrated to the table on the next save. An older `relay.sh` that predates the
table format drops table rows on save, so repos must update (§12) before saving.

## 6. Save operation

### Triggering (L1 + L2)

The save is agent-invoked, two ways:

- **L1, explicit.** The user runs the `session-save` command or skill
  (`/session-save` in Claude Code and OpenCode, `$session-save` in Codex, the
  `session-save` skill in Cursor and Grok). Highest fidelity: the agent writes
  from full in-context memory.
- **L2, agent-prompted.** The adapter's `AGENTS.md` block tells the agent to save
  on an explicit signal ("done for today", "let's continue tomorrow") and to
  offer a save in one line when unsure the session is ending.

If neither fires before a hard exit, that one session's handoff is lost.

### Behavior (deterministic, via `relay save`)

The agent pipes the six sections on stdin and passes the digest:

```bash
printf '%s\n' '<six sections>' \
  | .relay/relay.sh save --dir .session-log --digest '<one-line digest>'
```

`relay.sh` reads stdin first (authoring is lock-free), then, **holding the lock**
(§10):

1. Counts the sessions already in `history/<today>.md` and stamps frontmatter
   with `session: N+1`. Appends the handoff after a `---` rule, or creates the
   file as session 1.
2. Overwrites `latest.md` with **this session's** handoff (not the whole day).
3. Rebuilds `index.md`: puts today's row first (dropping any earlier row for
   today), keeps ≤ 10 rows.
4. Prunes `history/` to the **10 most recent dated files**.

A missing `.session-log/` is created on the fly. After the handoff, the save
skill goes on to capture durable knowledge (facts and lessons); that half is
covered in the learning design.

## 7. Load operation (automatic at session start)

`relay load` emits, in order:

1. A **recency line**: `Last saved: 2026-06-20 (today)`,
   `Last saved: 2026-06-18 (2 day(s) ago)`, or a ⚠ flag past 3 days
   (`⚠ Last saved: 2026-06-11 — 9 days ago`).
2. **`latest.md` in full**, soft-capped at 800 words (`RELAY_WORD_CAP`), with a
   truncation note pointing at the file if the cap is hit.
3. **Durable knowledge**: facts and active lessons, every entry named by its id.
   The top-ranked entries appear in full under their own word budgets (so they
   cannot crowd out the handoff); the rest are listed by id in one `More` line.
   Truncation is always stated.
4. **`index.md` verbatim**: the dated ≤ 10-day map.
5. A closing pointer: the handoff and index are summaries; if the task touches
   an earlier day in the index, open `.session-log/history/<date>.md` first.

Output format follows the CLI: plain text (`--format text`, the default), a
Codex `hookSpecificOutput.additionalContext` JSON object (`--format codex`), or a
top-level `systemMessage` JSON object (`--format grok`).

Load **never blocks**: with no `latest.md` it prints nothing and exits cleanly,
and the hook wrappers swallow errors.

## 8. Rolling-window mechanics

- The unit is the **dated daily file**; the window is the **10 most recent dated
  files**. Calendar gaps (weekends) do not shrink it.
- The 11th distinct day prunes the oldest file and its index row.
- Same-day sessions **append** to that day's file; `latest.md` reflects the most
  recent single session; `index.md` holds exactly one row per day.

## 9. Cross-CLI adapters

Every adapter calls the same `relay.sh`; only the load surface and the command
location differ. All five append their instruction block to `AGENTS.md`, between
`# >>> relay >>>` and `# <<< relay <<<` markers.

| CLI | Load at session start | Save / learn / compact |
|---|---|---|
| **Claude Code** | `SessionStart` hook in `.claude/settings.json` runs `relay load`; stdout is injected | `.claude/skills/` (shared skill set): `/session-save`, `/relay-learn`, `/relay-compact` |
| **Codex** | `SessionStart` hook in `.codex/hooks.json` runs `relay load --format codex` (`additionalContext`, limit raised to 6000; trusted once via `/hooks`); `AGENTS.md` block is the fallback | `.codex/skills/`: `$session-save`, `$relay-learn`, `$relay-compact` |
| **OpenCode** | `opencode.json` `instructions` points at `.session-log/relay-instructions.md`, a `relay load` snapshot refreshed by save and learn | `.opencode/commands/`: `/session-save`, `/relay-learn`, `/relay-compact` |
| **Cursor** | `AGENTS.md` block tells the agent to read `latest.md` and `index.md` (no hook) | `.cursor/skills/` (shared skill set) |
| **Grok Build** | `.grok/hooks/relay.json` runs `relay load --format grok` after a one-time `/hooks-trust`; `AGENTS.md` block is the fallback | `.grok/skills/` (shared skill set) |

Claude Code, Cursor, and Grok share one skill set (`adapters/skills/`). Codex and
OpenCode carry their own copies because their command formats differ. Cursor and
OpenCode do not run `relay load` live, so on Cursor the agent sees the handoff
and index but not the knowledge block.

## 10. Concurrency and locking

For multiple agents working the same repo at once:

- `relay.sh` wraps every file mutation in a **portable `mkdir` lock** on
  `.session-log/.lock/` (no `flock`, so it works on stock macOS). The lock
  directory holds an `info` file with the holder's PID and start time.
- **Authoring happens before the lock.** `save` reads stdin first, so a
  concurrent saver waits only for the brief write, not for the other agent's
  thinking.
- **Wait your turn:** a second writer polls once a second and proceeds when the
  lock is released.
- **No wedged locks:** a lock whose holder PID is gone, or which is older than
  30 seconds (`RELAY_LOCK_TIMEOUT`), is reclaimed. A writer that waits longer
  than 30 seconds gives up with `relay: lock wait timeout`. The lock is also
  released on exit via a trap.

## 11. Storage and git

- **`.session-log/` (the data) is gitignored, local-only, per-repo.** The
  installer adds it to `.gitignore`. Handoffs never go to git or any cloud.
- **The tool is committed:** `.relay/`, the per-CLI skills, commands, and hook
  config, and the `AGENTS.md` blocks. That is how Relay travels to other repos,
  machines, and people; each checkout then generates its own local handoffs.
- Git worktrees each get their own `.session-log/`.
- The one path from local data into a committed file is a **graduated lesson**,
  which the user approves (see the learning design).

## 12. Installer and distribution

### The transfer package

The deliverable is a **single self-contained `dist/install.sh`**: `relay.sh`, the
adapters, and the smoke test are embedded as heredocs, so it needs no fetch at
install time.

- **Source vs deliverable:** the repo holds readable sources (`relay.sh`,
  `install.sh`, `adapters/`, `tests/`). `bash bundle.sh` concatenates them into
  `dist/install.sh`. CI fails if the bundle is out of date with the sources.
- **How it travels:**
  `curl -fsSL https://raw.githubusercontent.com/jeremybrice/relay/main/dist/install.sh | bash`
  from the target repo's root, or download it, read it, and run `bash install.sh`.
  A local clone can run the source `install.sh` directly.
- **Updates:** there is no separate update command. Re-run the installer with
  `--detect`; it replaces `.relay/`, rewrites each `AGENTS.md` block in place, and
  leaves `.session-log/` alone. Then commit `.relay/`.

### Install behavior

1. **Choose CLIs.** With a terminal and no flags, a picker lists the five CLIs
   with any already present in the repo pre-checked. `--clis claude,codex,…`
   skips the prompt; `--detect` (and any run without a terminal) wires only the
   CLIs already present.
2. **Lay down** `.relay/` (the tool) and the `.session-log/history/` skeleton.
3. **Wire** each chosen CLI (§9). JSON configs are merged with `jq`, falling back
   to `python3`, falling back to printing the entry for a manual merge.
4. **Gitignore** `.session-log/`.

The installer is **additive and idempotent**: each `AGENTS.md` block is keyed by
its header line and replaced in place on re-run; hook entries are skipped if
already present. Re-installing over an older install moves Claude Code's block
out of `CLAUDE.md` into `AGENTS.md` and removes legacy command files, leaving
the rest of `CLAUDE.md` untouched.

## 13. Error handling

- **Load** never blocks; absent files are skipped; the stale flag is surfaced,
  not fatal.
- **Save** self-heals a missing directory; lock contention waits up to 30
  seconds, then fails with a clear message rather than writing unlocked.
- **Prune** is best-effort; a failure leaves extra history rather than crashing.
- **Install** is additive and marker-delimited, so it can be reversed by hand.
- **Knowledge add** rejects unknown options and more than one body argument
  (exit 2, nothing written). A store with a newer `.relay-format` makes every
  locked write exit 1.

## 14. Testing

The suite runs with `bash tests/run.sh` plus `bash tests/smoke-compact.sh`. CI
(`.github/workflows/tests.yml`) runs both on Ubuntu and macOS for pull requests
and pushes to `main`. Coverage includes:

- **Lifecycle:** 11 days of saves cap `history/` at 10 files and the index at 10
  rows; same-day saves append and replace the day's row.
- **Index tables:** padded table output, legacy line migration, digest flattening.
- **Concurrency:** parallel saves serialize under the lock with no clobber.
- **Staleness:** a 9-day-old `latest.md` surfaces the ⚠ flag.
- **Install:** idempotency, CLI picker, `--detect`, upgrade over older installs,
  and per-adapter wiring for all five CLIs.
- **Bundle:** `dist/install.sh` matches the sources.
- **Knowledge:** add, conflict, resolve, graduate, ungraduate, prune, compact,
  restore, and load caps.

## 15. Naming

**Relay** (agents relay the baton). Data dir `.session-log/`, tool dir `.relay/`:
descriptive and brand-neutral.

## 16. Alternatives considered

- **Loading model:** last-session-only (ignores the 10-day intent) and a full
  10-day digest (token tax every session) were rejected in favor of **full last
  session plus surfaced index**.
- **Handoff schema:** a lean 3-part form risked placeholder handoffs; the full
  Forge log is too heavy. Chose the **6-section structured** form.
- **Packaging:** a Claude-Code-only plugin fails cross-harness; a pure copy-in
  convention has no enforcement. Chose **portable core plus thin adapters**.
- **File operations:** agent-executed writes were rejected in favor of a
  **deterministic `relay.sh`**: reliability, testability, and the lock all
  require it.
- **Locking:** `flock` was the first design but is missing on stock macOS.
  Chose a **`mkdir` lock** with PID and age-based reclaim.
- **Index format:** JSON was considered and rejected. The index is read by
  agents, written by bash, and derived from history, so a padded Markdown table
  serves every reader. A `--json` output can be added if a program consumer
  appears.
- **Storage:** committed or cloud-synced data was rejected in favor of
  **local-only, gitignored** data.
- **Distribution:** a thin fetch-installer (needs network) and a Claude Code
  plugin (one CLI only) were rejected in favor of a **single embedded
  `install.sh`**.

## 17. Future

- **Curation freeze.** No new knowledge subcommands until re-assertion is
  visible in real stores: at least one lesson in some install reaching
  `sessions: 2` by re-assertion of a loaded id. Check by listing `sessions:`
  across installs.

- **L3 hook-automatic save:** a `SessionEnd` (Claude Code) / `Stop` (Codex) hook
  that writes the handoff from the session transcript when L1 and L2 did not
  fire. Pending a viability spike.
- **Today's earlier sessions at load:** on multi-session days, also inject the
  day's earlier handoffs under the shared cap.
- **Knowledge for Cursor and OpenCode:** both read static files today, so Cursor
  never sees the knowledge block.
- **`PreCompact` checkpoint:** write a handoff before context compaction.
- **`git diff` crash-recovery stub** for the hard-kill case L3 cannot catch.
- **`relay digest`:** one rolled-up brief across the full 10-day window on demand.
- **Plugin or `npx` wrappers** as convenience installers.
