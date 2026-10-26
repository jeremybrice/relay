<!-- adapters/codex/AGENTS.relay.md -->
## Relay — session handoff (Codex)
At the START of a session, read `.session-log/latest.md` and `.session-log/index.md`
first — they are the last agent's handoff.
If the current task touches work from an earlier day listed in `index.md`,
open that day's `.session-log/history/<date>.md` before starting — the handoff
and index are summaries only.
When wrapping up ("done for today" / "continue tomorrow"), run `$session-save` to
persist a new handoff; offer it if unsure.
At wrap-up, also capture durable facts/lessons with `$relay-learn` (or inline
`knowledge add`). Graduation-ready lessons are asked about at session start (the
Ready block); never graduate without the user's yes.
