<!-- adapters/codex/skills/relay-learn/SKILL.md -->
---
name: relay-learn
description: Record a durable fact or lesson about this repo into Relay knowledge
---
Capture one durable piece of knowledge about THIS repo for future sessions.

1. Fact = durable repo truth (a command, path, gotcha, specific value, how one
   incident was resolved). Lesson = reusable rule for future, different tasks
   ("when X, prefer Y, because Z"). If it only makes sense for the task you just
   did, it is a fact, not a lesson.
2. Check for a match first (reuse the id, don't duplicate); use `--fact` or `--lesson`:

```bash
"${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --lesson --near 'a few key words' \
  --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log"
```

3. Write it with a short stable kebab-case `--id`, body on stdin via `-` (closing
   `RELAY_BODY` at the start of its line). The only options are `--fact`,
   `--lesson`, `--id`, `--ttl`, `--near` and `--dir`; anything else is rejected.

```bash
"${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --fact --id <slug> - \
  --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log" <<'RELAY_BODY'
<fact or lesson text>
RELAY_BODY
```

4. If a lesson is graduation-ready, tell the user it will be asked about at the next session start. Do not offer graduation now.
