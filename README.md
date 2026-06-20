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
