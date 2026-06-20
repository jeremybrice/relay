<!-- adapters/claude-code/CLAUDE.relay.md -->
## Relay — session handoff (L2)
When the user signals the session is wrapping up ("done for today", "let's
continue tomorrow", or a task completes and we're winding down), run
`/session-save` to persist a Relay handoff. If unsure the session is ending,
offer it in one line.
