---
name: relay-learn
description: Record a durable fact or lesson about this repo into Relay knowledge
---

Capture a single durable piece of knowledge about THIS repo for future sessions.

1. Decide the kind:
   - **Fact** — a durable truth about the repo (a command, a path, a gotcha).
   - **Lesson** — a behavioral pattern ("when X, prefer Y, because Z").
2. For a fact, first check for an existing match so you reuse its id instead of
   duplicating:

   ```bash
   "$PWD/.relay/relay.sh" knowledge add --fact --near '<the fact text>' \
     --dir "$PWD/.session-log"
   ```

3. Write it (reuse a surfaced id, or coin a short stable kebab-case slug). Add
   `--ttl <days>` to a fact that is only true for a while; omit it for durable
   truths:

   ```bash
   "$PWD/.relay/relay.sh" knowledge add --fact --id <slug> '<fact text>' \
     --dir "$PWD/.session-log"
   "$PWD/.relay/relay.sh" knowledge add --lesson --id <slug> '<lesson text>' \
     --dir "$PWD/.session-log"
   ```

4. If the tool reports a lesson is graduation-ready, offer (one line) to run
   `knowledge graduate <slug>` — never graduate without the user's okay.

Do not write `.session-log/relay-instructions.md`. Session start reads
`.session-log/latest.md` and `.session-log/index.md` only.
