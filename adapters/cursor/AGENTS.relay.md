<!-- adapters/cursor/AGENTS.relay.md -->
## Relay — session handoff (Cursor)
At the START of a session, read `.session-log/latest.md` and `.session-log/index.md`
if they exist — they are the last agent's handoff. If missing, continue.
If the current task touches work from an earlier day listed in `index.md`,
open that day's `.session-log/history/<date>.md` before starting — the handoff
and index are summaries only.
When the user signals the session is wrapping up ("done for today", "let's
continue tomorrow", or a task completes and we're winding down), run the
`session-save` skill to persist a Relay handoff. If unsure the session is ending,
offer it in one line.
At wrap-up, also capture durable facts/lessons with the `relay-learn` skill (or inline
`knowledge add`), and surface any graduation-ready lesson for the user to approve.
If knowledge is over cap, offer the `relay-compact` skill in one line.
