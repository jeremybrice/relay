---
name: relay-learn
description: Record a durable fact or lesson about this repo into Relay knowledge
---

Capture a single durable piece of knowledge about THIS repo for future sessions.

1. Decide the kind:
   - **Fact**: a durable truth about the repo (a command, a path, a gotcha, a
     specific value or count, how one incident was resolved).
   - **Lesson**: a reusable rule for future, different tasks, phrased "when X,
     prefer Y, because Z". If it only makes sense for the task you just did,
     it is a fact, not a lesson.
2. Look for an existing entry first so you reuse its id instead of duplicating.
   Use `--fact` or `--lesson` to match the kind:

```bash
"$PWD/.relay/relay.sh" knowledge add --lesson --near 'a few key words' \
  --dir "$PWD/.session-log"
```

3. Write it (reuse a surfaced id, or coin a short stable kebab-case slug). Pass
   the body on stdin with `-` so quotes and apostrophes need no escaping, and
   keep the closing `RELAY_BODY` at the start of its line. Add `--ttl <days>`
   to a fact that is only true for a while; omit it for durable truths. The
   only options are `--fact`, `--lesson`, `--id`, `--ttl`, `--near` and
   `--dir`; anything else is rejected.

```bash
"$PWD/.relay/relay.sh" knowledge add --fact --id <slug> - \
  --dir "$PWD/.session-log" <<'RELAY_BODY'
<fact or lesson text>
RELAY_BODY
```

4. If the tool reports a lesson is graduation-ready, offer (one line) to run
   `knowledge graduate <slug>`. Never graduate without the user's okay.

Do not write `.session-log/relay-instructions.md`. Session start reads
`.session-log/latest.md` and `.session-log/index.md` only.
