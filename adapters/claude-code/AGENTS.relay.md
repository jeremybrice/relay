<!-- adapters/claude-code/AGENTS.relay.md -->
## Relay — session handoff (Claude Code)
The last handoff, active knowledge, and the session index load at session start
via the SessionStart hook. They are summaries only: if the current task touches
work from an earlier day listed in the index, open that day's
`.session-log/history/<date>.md` before starting.
When the user signals the session is wrapping up ("done for today", "let's
continue tomorrow", or a task completes and we're winding down), run
`/session-save` to persist a Relay handoff. If unsure the session is ending,
offer it in one line.
At wrap-up, also capture durable facts/lessons with `/relay-learn` (or inline
`knowledge add`), and surface any graduation-ready lesson for the user to approve.
If knowledge is over cap, offer `/relay-compact` in one line — never run it unasked.
