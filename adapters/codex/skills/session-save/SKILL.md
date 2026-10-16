<!-- adapters/codex/skills/session-save/SKILL.md -->
---
name: session-save
description: Save a Relay handoff for the next Codex session
---
Persist a Relay handoff for the next agent.

1. Author the six sections (`## Summary`, `## Changed`, `## Decisions`, `## Next`,
   `## Watch out`, `## Open questions`). Carry forward every still-open item from
   the loaded handoff's `## Next` and `## Open questions`: this handoff replaces it.
   Compose a one-line digest with no single quotes in it.
2. Run (keep the closing `RELAY_HANDOFF` at the start of its line):

```bash
"${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" save --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log" \
  --digest '<<one-line digest>>' <<'RELAY_HANDOFF'
<<six sections>>
RELAY_HANDOFF
```

3. Reply: "Handoff saved for the next session."
4. Reinforce lessons. Session start listed each lesson with its id. For each
   loaded lesson that actually applied again, re-assert it under the SAME id:

```bash
"${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --lesson --id <existing-id> - \
  --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log" <<'RELAY_BODY'
<<lesson text>>
RELAY_BODY
```

   Restate the loaded text rather than paraphrasing it. If the lesson was listed
   only by id, open it first with `relay.sh knowledge why <id>` (same `--dir`).
   Do not re-assert a lesson only because it was loaded.
5. Capture new durable knowledge with `$relay-learn` (skip if none). Offer
   graduation only when prompted and approved.
6. If `knowledge list` reports counts over cap (or the session-start load warned
   "(⚠ N ... over cap ...)"), offer `$relay-compact` in one line. Never run it unasked.
