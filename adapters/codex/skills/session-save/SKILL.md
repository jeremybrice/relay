<!-- adapters/codex/skills/session-save/SKILL.md -->
---
name: session-save
description: Save a Relay handoff for the next Codex session
---
Persist a Relay handoff for the next agent.

1. Author the six sections (`## Summary`, `## Changed`, `## Decisions`, `## Next`,
   `## Watch out`, `## Open questions`) and a one-line digest.
2. Run:

   ```bash
   printf '%s\n' '<<six sections>>' \
     | "${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" save \
         --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log" \
         --digest '<<one-line digest>>'
   ```
3. Reply: "Handoff saved for the next session."
4. Then capture durable knowledge (skip if none): facts via
   `knowledge add --fact --near` then `--fact --id <slug>`; lessons via
   `knowledge add --lesson --id <slug>`, using `"${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh"`
   and `--dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log"`. Offer graduation only when prompted and approved.
