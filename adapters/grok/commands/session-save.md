<!-- adapters/grok/commands/session-save.md -->
---
description: Save a Relay handoff so the next Grok session can pick up where you left off
---
Persist a Relay handoff for the next agent.

1. Author the six sections as concise markdown — `## Summary`, `## Changed`,
   `## Decisions`, `## Next`, `## Watch out`, `## Open questions` — naming real
   files/paths and dated facts. Compose a one-line digest.
2. Persist it. The script owns all file writes, rotation, and locking:

   ```bash
   printf '%s\n' '<<the six sections as markdown>>' \
     | "${GROK_WORKSPACE_ROOT:-$PWD}/.relay/relay.sh" save \
         --dir "${GROK_WORKSPACE_ROOT:-$PWD}/.session-log" \
         --digest '<<one-line digest>>'
   ```
3. Reply: "Handoff saved for the next session."
4. Then capture durable knowledge from this session (skip if none): for each
   permanent repo truth run `knowledge add --fact --near` then `--fact --id <slug>`;
   for each behavioral lesson run `knowledge add --lesson --id <slug>`. Use
   `"${GROK_WORKSPACE_ROOT:-$PWD}/.relay/relay.sh"` and
   `--dir "${GROK_WORKSPACE_ROOT:-$PWD}/.session-log"`.
   If the tool says a lesson is graduation-ready, offer graduation in one line.
