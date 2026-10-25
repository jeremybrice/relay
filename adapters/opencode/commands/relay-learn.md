<!-- adapters/opencode/commands/relay-learn.md -->
---
description: Record a durable fact or lesson about this repo into Relay knowledge
---
Capture a single durable piece of knowledge about THIS repo for future sessions.

1. Decide the kind:
   - **Fact**: a durable truth about the repo (a command, a path, a gotcha, a
     specific value or count, how one incident was resolved).
   - **Lesson**: a reusable rule for future, different tasks, phrased "when X,
     prefer Y, because Z". If it only makes sense for the task you just did,
     it is a fact, not a lesson.
2. Look for an existing entry first so you reuse its id; use `--fact` or `--lesson`:

```bash
"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --lesson --near 'a few key words' \
  --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log"
```

3. Write it (reuse a surfaced id, or coin a short stable kebab-case slug), body on
   stdin via `-` (closing `RELAY_BODY` at the start of its line). Add `--ttl <days>`
   to a fact that is only true for a while. The only options are `--fact`,
   `--lesson`, `--id`, `--ttl`, `--near` and `--dir`; anything else is rejected.

```bash
"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --fact --id <slug> - \
  --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" <<'RELAY_BODY'
<fact or lesson text>
RELAY_BODY
```

4. Refresh the snapshot opencode auto-loads next session:

```bash
"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" load --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" \
  > "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log/relay-instructions.md"
```

5. If the tool reports a lesson is graduation-ready, tell the user it will be asked
   about at the next session start. Do not offer graduation now.
