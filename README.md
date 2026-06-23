# Relay — portable session handoff

Agents hand off to each other day-to-day across a rolling 10-day window. Local,
gitignored, cross-harness (Claude Code + Codex).

## Install (in any repo)

```bash
curl -fsSL https://<host>/relay/install.sh | bash
# or: download install.sh, read it, then `bash install.sh`
```

It lays down `.relay/` (the tool, committed), wires the SessionStart hook + a save
command for whichever harness it finds, and gitignores `.session-log/` (your
handoffs — local only).

## Use

- Auto-loads the last handoff at session start.
- Run `/session-save` (Claude Code) or `$session-save` (Codex) to write one — or
  the agent offers when you wrap up.

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
