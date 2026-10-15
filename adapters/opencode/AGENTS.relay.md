<!-- adapters/opencode/AGENTS.relay.md -->
## Relay — session handoff (OpenCode)
At the START of a session, the last handoff + active knowledge load automatically
via the `instructions` entry in `opencode.json` (from
`.session-log/relay-instructions.md`). If that file is missing or empty, fall back
to reading `.session-log/latest.md` and `.session-log/index.md` directly.
If the current task touches work from an earlier day listed in `index.md`,
open that day's `.session-log/history/<date>.md` before starting — the handoff
and index are summaries only.
When the user signals the session is wrapping up ("done for today", "let's
continue tomorrow", or a task completes and we're winding down), run
`/session-save` to persist a Relay handoff. If unsure the session is ending,
offer it in one line.
At wrap-up, also capture durable facts/lessons with `/relay-learn` (or inline
`knowledge add`), and surface any graduation-ready lesson for the user to approve.
