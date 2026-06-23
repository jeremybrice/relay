<!-- adapters/codex/skills/relay-learn/SKILL.md -->
---
name: relay-learn
description: Record a durable fact or lesson about this repo into Relay knowledge
---
Capture one durable piece of knowledge about THIS repo for future sessions.

1. Fact = durable repo truth; Lesson = behavioral pattern ("when X, prefer Y").
2. For a fact, check for a match first (reuse the id, don't duplicate):

   ```bash
   "${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --fact --near '<fact text>' \
     --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log"
   ```
3. Write it with a short stable kebab-case `--id`:

   ```bash
   "${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --lesson --id <slug> '<text>' \
     --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log"
   ```
4. If a lesson is graduation-ready, offer to `knowledge graduate <slug>` — only with the user's okay.
