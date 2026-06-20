<!-- adapters/codex/AGENTS.relay.md -->
## Relay — session handoff (L2 + load fallback)
At the START of a session, read `.session-log/latest.md` and `.session-log/index.md`
first — they are the last agent's handoff. When wrapping up ("done for today" /
"continue tomorrow"), run `$session-save` to persist a new handoff; offer it if unsure.
