---
name: session-save
description: Save a Relay handoff so the next session can pick up where you left off
---

Persist a Relay handoff for the next agent.

1. Author the six sections as concise markdown (`## Summary`, `## Changed`,
   `## Decisions`, `## Next`, `## Watch out`, `## Open questions`), naming real
   files/paths and dated facts. Carry forward every still-open item from the
   loaded handoff's `## Next` and `## Open questions`: this handoff replaces it.
   Compose a one-line digest with no single quotes in it.
2. Persist it. The script owns all file writes, rotation, and locking. The
   quoted heredoc passes the markdown through untouched, apostrophes included.
   Keep the closing `RELAY_HANDOFF` at the start of its line:

```bash
"$PWD/.relay/relay.sh" save --dir "$PWD/.session-log" \
  --digest '<<one-line digest>>' <<'RELAY_HANDOFF'
<<the six sections as markdown>>
RELAY_HANDOFF
```

3. Reply: "Handoff saved for the next session."
4. Reinforce lessons. Session start listed each lesson with its id. For each
   loaded lesson that actually applied again in this session, re-assert it
   under the SAME id (sharpen the wording if you learned more):

```bash
"$PWD/.relay/relay.sh" knowledge add --lesson --id <existing-id> - \
  --dir "$PWD/.session-log" <<'RELAY_BODY'
<<lesson text>>
RELAY_BODY
```

   Restate the loaded text rather than paraphrasing it. If the lesson was listed
   only by id, open it first with `"$PWD/.relay/relay.sh" knowledge why <id>`.
   Re-asserting on a new day is what moves a lesson toward graduation. Do not
   re-assert a lesson only because it was loaded.
5. Capture new durable knowledge from this session (skip if none) with the
   `relay-learn` skill. If the tool says a lesson is graduation-ready, offer
   graduation in one line. Never graduate without the user's okay.
6. If `knowledge list` reports counts over cap (or a load warned
   "(⚠ N ... over cap ...)"), offer `relay-compact` in one line.
   Never run it unasked.

Do not write `.session-log/relay-instructions.md`. Session start reads
`.session-log/latest.md` and `.session-log/index.md` only.
