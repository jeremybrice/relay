---
name: session-save
description: Save a Relay handoff so the next session can pick up where you left off
---

Persist a Relay handoff for the next agent.

1. Author the six sections as concise markdown — `## Summary`, `## Changed`,
   `## Decisions`, `## Next`, `## Watch out`, `## Open questions` — naming real
   files/paths and dated facts. Compose a one-line digest.
2. Persist it. The script owns all file writes, rotation, and locking:

   ```bash
   printf '%s\n' '<<the six sections as markdown>>' \
     | "$PWD/.relay/relay.sh" save \
         --dir "$PWD/.session-log" \
         --digest '<<one-line digest>>'
   ```

3. Reply: "Handoff saved for the next session."
4. Then capture durable knowledge from this session (skip if none) using the
   `relay-learn` skill, or call `"$PWD/.relay/relay.sh"` `knowledge add` with
   `--dir "$PWD/.session-log"`. If the tool says a lesson is graduation-ready,
   offer graduation in one line. Never graduate without the user's okay.
5. If `knowledge list` reports counts over cap (or a load warned
   "(⚠ N ... over cap ...)"), offer `relay-compact` in one line.
   Never run it unasked.

Do not write `.session-log/relay-instructions.md`. Session start reads
`.session-log/latest.md` and `.session-log/index.md` only.
