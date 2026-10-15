<!-- adapters/opencode/commands/relay-learn.md -->
---
description: Record a durable fact or lesson about this repo into Relay knowledge
---
Capture a single durable piece of knowledge about THIS repo for future sessions.

1. Decide the kind:
   - **Fact** — a durable truth about the repo (a command, a path, a gotcha).
   - **Lesson** — a behavioral pattern ("when X, prefer Y, because Z").
2. For a fact, first check for an existing match so you reuse its id instead of
   duplicating:

   ```bash
   "${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --fact --near '<the fact text>' \
     --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log"
   ```
3. Write it (reuse a surfaced id, or coin a short stable kebab-case slug). Add
   `--ttl <days>` to a fact that is only true for a while (e.g. the current sprint);
   omit it for durable truths:

   ```bash
   "${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --fact --id <slug> '<fact text>' \
     --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log"
   # time-bound fact: ... knowledge add --fact --id current-sprint --ttl 14 '...' --dir ...
   # or a lesson:
   "${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --lesson --id <slug> '<lesson text>' \
     --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log"
   ```
4. Refresh the snapshot opencode auto-loads next session so the new knowledge
   is in context the moment the next session starts:

   ```bash
   "${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" load --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" \
     > "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log/relay-instructions.md"
   ```
5. If the tool reports a lesson is graduation-ready, offer (one line) to run
   `knowledge graduate <slug>` — never graduate without the user's okay.
