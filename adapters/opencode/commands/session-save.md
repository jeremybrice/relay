<!-- adapters/opencode/commands/session-save.md -->
---
description: Save a Relay handoff so the next opencode session can pick up where you left off
---
Persist a Relay handoff for the next agent.

1. Author the six sections as concise markdown — `## Summary`, `## Changed`,
   `## Decisions`, `## Next`, `## Watch out`, `## Open questions` — naming real
   files/paths and dated facts. Compose a one-line digest.
2. Persist it. The script owns all file writes, rotation, and locking:

   ```bash
   printf '%s\n' '<<the six sections as markdown>>' \
     | "${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" save \
         --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" \
         --digest '<<one-line digest>>'
   ```
3. Reply: "Handoff saved for the next session."
4. Refresh the snapshot opencode auto-loads next session via `opencode.json`'s
   `instructions` field, so the new handoff is in context the moment the next
   session starts:

   ```bash
   "${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" load --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" \
     > "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log/relay-instructions.md"
   ```
5. Then capture durable knowledge from this session (skip if none): for each
   permanent repo truth run `knowledge add --fact --near` then `--fact --id <slug>`;
   for each behavioral lesson run `knowledge add --lesson --id <slug>`. Use
   `"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh"` and
   `--dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log"`. Re-run the step-4 load
   after the knowledge writes so the snapshot stays current. If the tool says a
   lesson is graduation-ready, offer graduation in one line.
