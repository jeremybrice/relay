<!-- adapters/opencode/commands/session-save.md -->
---
description: Save a Relay handoff so the next opencode session can pick up where you left off
---
Persist a Relay handoff for the next agent.

1. Author the six sections as concise markdown (`## Summary`, `## Changed`,
   `## Decisions`, `## Next`, `## Watch out`, `## Open questions`), naming real
   files/paths and dated facts. Carry forward every still-open item from the
   loaded handoff's `## Next` and `## Open questions`: this handoff replaces it.
   Compose a one-line digest with no single quotes in it.
2. Persist it (keep the closing `RELAY_HANDOFF` at the start of its line):

```bash
"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" save --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" \
  --digest '<<one-line digest>>' <<'RELAY_HANDOFF'
<<the six sections as markdown>>
RELAY_HANDOFF
```

3. Reply: "Handoff saved for the next session."
4. Reinforce lessons. Session start listed each lesson with its id. For each
   loaded lesson that actually applied again, re-assert it under the SAME id:

```bash
"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --lesson --id <existing-id> - \
  --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" <<'RELAY_BODY'
<<lesson text>>
RELAY_BODY
```

   Do not re-assert a lesson only because it was loaded.
5. Capture new durable knowledge with `/relay-learn` (skip if none). If the tool
   says a lesson is graduation-ready, offer graduation in one line.
6. Refresh the snapshot opencode auto-loads next session via `opencode.json`'s
   `instructions` field (run this after any knowledge writes too):

```bash
"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" load --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" \
  > "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log/relay-instructions.md"
```

7. If `knowledge list` reports counts over cap (or step 6's load warned
   "(⚠ N ... over cap ...)"), offer `/relay-compact` in one line. Never run it unasked.
