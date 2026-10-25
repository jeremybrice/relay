# Graduation at session start + correction inbox: design

Date: 2026-10-25
Status: approved by Jeremy 2026-10-25
Origin: review of BayramAnnakov/claude-reflect against Relay (this session). Two of its ideas
are borrowed; none of its code is.

## 1. Why

Relay's learning loop is capture → reinforce → graduate. Measured across the 10 installs on
2026-10-25:

- **Reinforcement works.** talelog has 12 lessons at `sessions >= 2` (top: 6). The curation
  freeze in design-spec §17 asked for one; its exit condition is met.
- **Graduation never happens.** 7 talelog lessons are at `sessions >= 3` (graduation-ready);
  0 lessons are graduated anywhere. talelog's history shows why: "Graduate
  `zsh-no-word-split-refs` and `no-edit-running-script` (graduation-ready, offer unanswered)?"
  rides forward in Open questions for 3+ days. A one-line offer at wrap-up, when Jeremy is
  leaving, does not get answered. claude-reflect measured the same thing (102 queued items,
  none ever reviewed) and rebuilt around deciding in the moment.
- **Ready lessons are too long to become rules.** They run 83 to 219 words because each
  re-assertion appends dated notes. `graduate` today copies the whole body into AGENTS.md.
- **Corrections go missing.** Lessons are written by the agent at save time from memory.
  A correction made early in a long session, especially before a context compaction, is
  often gone by then.
- **Jeremy's corrections have no keyword shape.** He works by voice (Wispr). Corrections are
  iterative: "okay, let's try this instead", "can we change this?", then "oh no, that's not
  working", then agreement. Any per-prompt pattern filter (claude-reflect's approach) misses
  these; "can we change this?" ends in a question mark and gets thrown out.

## 2. Goals

1. A graduation-ready lesson is put in front of Jeremy at the start of a session, as a
   proposed one-line rule, and gets a decision: yes, edit, not yet, or drop.
2. "Not yet" stays quiet until there is new evidence (the lesson is re-asserted on another
   day). It never nags on a timer.
3. What graduates into AGENTS.md is a short rule, not the lesson body. The body stays in
   knowledge as the "why".
4. At save time the agent sees every user turn of the session, read from the harness's own
   transcript on disk, so corrections made hours earlier or before compaction feed lessons.
5. Works under Claude Code, Codex, and Grok, through the same `relay.sh` core.

## 3. Non-goals

- No per-prompt hook, no background capture, no model call per message.
- No confidence scoring or regex classification of corrections. A model (the saving agent)
  reads the turns; the existing 3-distinct-day gate filters one-offs.
- No rewrite of rules that are already graduated.
- No Claude Code mod in this project (see §8).
- Cursor and OpenCode stay as they are (they have no hook and no transcript path).

## 4. Anti-goals (failure even if it technically works)

- The session-start question becomes a wall Jeremy has to get through before every task.
- Transcript content gets written into `.session-log/` or any committed file. The inbox is
  read, used, and discarded.
- The agent edits AGENTS.md or knowledge files directly. Every write still goes through
  `relay.sh` under the lock (the core invariant).
- A rule lands in AGENTS.md without Jeremy's explicit yes.

## 5. Part 1: graduation at session start

### 5.1 What the user sees

On session start, `relay.sh load` checks for graduation-ready lessons. If any exist:

- **A visible line in the tool's UI** (Claude Code and Codex both show a hook's
  `systemMessage` to the user): `Relay: 2 lessons ready to become rules. I'll ask before we start.`
- **A block in the agent's context**, placed directly under the "Last saved" line, above
  the handoff:

```
## Ready to become rules (ask before starting work)
Before acting on the user's first message, ask once about each lesson below.
Propose a one-line rule (at most 240 characters) for each. Accept: yes / edit / not yet / drop.
- `no-edit-running-script` (sessions:6): <full lesson body>
- `zsh-no-word-split-refs` (sessions:5): <full lesson body>
(+4 more ready; they come up next session)
```

The agent cannot speak before Jeremy does: a hook only adds context. So the question comes
in the agent's reply to his first message, before it starts on that message's task. In
Claude Code the agent uses its multiple-choice question tool (AskUserQuestion), one question
per lesson, with the drafted rule as the "yes" option's text. In Codex and Grok it asks in
plain text, numbered.

### 5.2 The four answers

| Answer | Command | Effect |
|---|---|---|
| Yes | `relay.sh knowledge graduate <id> --rule -` (rule on stdin) | Rule block written to the instruction file; lesson moves to `lessons/graduated/` as today |
| Edit | same, with Jeremy's wording | same |
| Not yet | `relay.sh knowledge defer <id>` | Lesson hidden from the ready block until re-asserted on a later day |
| Drop | `relay.sh knowledge supersede <id>` (exists) | Lesson retired, kept in `superseded/` |

If Jeremy ignores the question and just keeps working, nothing is recorded and it comes
back next session. That is deliberate: no answer is not a "not yet".

### 5.3 Rules for the ready block

- **Ready** = active lesson with `sessions >= RELAY_GRADUATE_AT` (default 3) and not
  deferred (below).
- **At most 3 per session** (`RELAY_READY_MAX`, default 3), ranked by `sessions` then
  recency. The rest are counted on one line. talelog's first run surfaces 3 of 7, then 3,
  then 1, so it is never a wall.
- **Deferred** = frontmatter `deferred_at: <sessions value when deferred>`. A deferred
  lesson is ready again only once `sessions > deferred_at`, which can only happen by
  re-assertion on a new day. `_k_add_lesson` leaves `deferred_at` alone; the comparison
  does the work.
- **Own word budget.** The ready block has its own cap (`RELAY_READY_CAP`, default 600
  words), separate from `RELAY_LESSONS_CAP`, because ready bodies run 83 to 219 words and
  three of them would otherwise push every normal lesson to an id-only line. Fill greedily
  in rank order up to 3 lessons or the cap, whichever comes first; always show at least one.
  Bodies are shown in full (the agent needs them to draft the rule). Lessons in the ready
  block are not repeated in the normal lessons list. (Claude's call.)
- **Fresh starts only.** The ready block and the visible line appear only when the session
  really starts: Claude Code `source` of `startup` or `clear`, Codex `startup`. On
  `resume` and `compact` the hook loads as today with no ready block, so a compaction never
  interrupts work with the question. The hook reads `source` from its stdin JSON and passes
  `--fresh` to `load`; without `--fresh`, `load` omits the block. If `source` is missing
  (older harness), treat it as fresh. (Claude's call.)
- **Save no longer offers graduation.** Step 5 of the session-save skill changes from
  "offer graduation in one line" to "if the tool says a lesson is graduation-ready, say it
  will come up at the next session start". The `graduation-ready` line `relay.sh` prints on
  reinforcement changes wording to match. The same wrap-up offer also appears in
  `adapters/skills/relay-learn/SKILL.md`, `adapters/skills/relay-compact/SKILL.md`, the
  Codex skill copies, and every `adapters/*/AGENTS.relay.md` block; all are updated to match.

### 5.4 `graduate --rule`

- `knowledge graduate <id>` without `--rule` keeps working exactly as today (body copied),
  so old skills and muscle memory do not break.
- With `--rule TEXT` or `--rule -` (stdin, quoted heredoc like other bodies): the text must
  be a single line, 240 characters or fewer, not empty. Otherwise refuse with a clear error
  and write nothing.
- The block written to the instruction file:

```
<!-- relay:learned:no-edit-running-script -->
- Never edit a script while it is running; copy it, edit the copy, swap after it exits. (why: relay knowledge why no-edit-running-script)
<!-- /relay:learned:no-edit-running-script -->
```

- `knowledge why <id>` is extended to also look in `lessons/graduated/`, so the pointer in
  the rule works (today `k_why` only searches `facts/` and `lessons/`).
- The graduated lesson file gets a `rule:` frontmatter field holding the rule text, so
  `knowledge list`'s drift check and `ungraduate` keep working unchanged (they key on the id
  markers, not the text).

### 5.5 Delivery per harness

| Harness | Visible line | Context block |
|---|---|---|
| Claude Code | hook emits JSON: `systemMessage` + `hookSpecificOutput.additionalContext` (new `--format claude`) | additionalContext |
| Codex | `systemMessage` added beside the existing `hookSpecificOutput.additionalContext` (`--format codex`) | additionalContext |
| Grok | none (Grok's format already uses `systemMessage` for the whole handoff) | as today |

The visible line is emitted only when at least one lesson is ready. With nothing ready,
output is byte-identical to today apart from the Claude Code switch to JSON.

## 6. Part 2: correction inbox (transcript turns at save)

### 6.1 Idea

No new capture. Each harness already writes the full session to disk, and that file is
complete even after context compaction. At save time, a new read-only command
`relay.sh turns` pulls out only the user's turns since the last save and prints them in a
compact form. The session-save skill runs it first, and the agent reads the arcs where
Jeremy pushed back or changed direction, then decides what became durable.

### 6.2 Where the transcript is

| Harness | Location | How `turns` finds the current session |
|---|---|---|
| Claude Code | `~/.claude/projects/<encoded path>/<session>.jsonl` | The SessionStart hook reads `transcript_path` from its stdin JSON and appends it to `.session-log/.transcripts`. `turns` picks the most recently modified listed file that still exists (the live session is the one being written). |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | Same hook mechanism if Codex's SessionStart stdin carries `transcript_path` (verify). Fallback: newest rollout from the last 2 days whose first `session_meta` line has `cwd` equal to the repo root. |
| Grok | `~/.grok/sessions/<url-encoded cwd>/prompt_history.jsonl` (user prompts only, with `session_id`) | Newest `session_id` in that file. No agent text is available, so turns are shown without the "agent said" line. |

**Which harness and session.** Each harness's copy of the session-save skill passes
`--harness claude|codex|grok` to `turns`, so a Codex save never reads a Claude Code
transcript. Within one harness, `turns` takes the most recently modified transcript for
this repo (the live session is the one being written). Two sessions of the same harness open
in the same repo folder at once is not supported: `turns` may read the other one. It prints
the transcript's path and first turn in its header so the agent can notice a mismatch and
say so. Separate worktrees are separate folders and are unaffected. (Claude's call; Jeremy
was asked and did not say he runs parallel sessions in one folder.)

If no transcript is found, `turns` prints one line (`relay: no transcript found for this
session; save from memory`) and exits 0. The save goes ahead as today.

`.session-log/.transcripts` holds paths only, is trimmed to the newest 20 lines on each
append, and lives in the already gitignored `.session-log/`.

### 6.3 What `turns` prints

```
## Your turns this session (since 14:02; 23 turns, 4 omitted as acknowledgements)
1. [14:05] agent said: "...rendered the panel with the default 2px border." → you: "okay let's try this instead, no border and a soft shadow"
2. [14:09] you: "oh no that's not working, it looks muddy on dark mode"
3. [14:12] you rejected a tool call: "don't touch the shared theme file"
...
```

- **Included:** real user prompts; tool-call rejections with the user's reason (these are
  corrections by definition); for Claude Code and Codex, the last ~25 words of the
  assistant text right before each user turn.
- **Excluded:** command and skill expansions, system reminders, hook output, and pure
  acknowledgements ("ok", "yes", "go ahead", "perfect") which are counted, not shown.
- **Pasted text is kept.** Wispr dictation reaches Claude Code wrapped in
  `<pasted_content>` tags, so a paste is usually Jeremy's own voice prompt. The tags are
  removed and the text is treated as his words. (Claude's call, found while planning.)
- **Each turn** over 80 words shows its first 60 words, ` … `, and its last 20, so a
  correction at either end of a long voice prompt survives. **Total cap** 1,500 words (`RELAY_TURNS_CAP`); if over,
  the oldest turns are dropped first, and the header says how many.
- **"Since"**: the timestamp of this transcript's last *successful* save, kept in
  `.session-log/.turns-cursor`, one line per transcript: `<transcript path><TAB><timestamp>`
  (trimmed to the newest 20 lines). `turns` only reads the cursor; it never moves it. It
  prints the transcript path and the newest turn's timestamp in its header, and also writes
  them to `.session-log/.turns-pending`. `relay.sh save` moves the cursor from
  `.turns-pending` after the handoff is written, under the lock. So an abandoned save or a
  second `turns` run skips nothing. A second save in the same session sees only new turns;
  the first save sees the whole session. (Claude's call.)
- **Nothing from the transcript is written to disk.** `turns` only prints. The cursor file
  holds a path and a timestamp.

### 6.4 The skill change

session-save gets a new first step:

> 0. Run `"$PWD/.relay/relay.sh" turns --dir "$PWD/.session-log"`. Read it for corrections:
> places where the user rejected, redirected, or said something was not working, and what
> they settled on. For each, ask: would this apply next week, on a different task? If yes,
> it is a lesson (a behavior: when X, do Y, because Z) or a fact (a truth about the repo).
> If it matches a loaded lesson, re-assert that id; otherwise add a new one with
> relay-learn. One-off redirects about the task at hand are not lessons. Use the turns for
> the handoff's Decisions too.

The step uses the existing `knowledge add` commands. The agent decides; `relay.sh` records.

### 6.5 Why this, not claude-reflect's capture

| | claude-reflect | This design |
|---|---|---|
| When | every prompt, as typed | once, at save |
| Who classifies | ~60 regexes, then an LLM pass later | the saving agent, reading the whole arc |
| Cost | hook per prompt (mod: a model call per prompt) | zero until save; then reading ≤1,500 words |
| Voice and iterative corrections | missed (no keyword, often a question) | seen |
| Survives compaction | yes (queue file) | yes (transcript file) |
| Writes to disk mid-session | yes | no |

## 7. Flow, end to end

```
session start ──► hook ──► relay.sh load
                    │         ├─ visible line: "2 lessons ready to become rules"
                    │         └─ context: Ready block (≤3) + handoff + knowledge + index
                    └─ records transcript_path → .session-log/.transcripts
first message ──► agent asks yes / edit / not yet / drop
                    ├─ yes/edit → knowledge graduate <id> --rule -   → AGENTS.md (one line)
                    ├─ not yet  → knowledge defer <id>               → quiet until re-asserted
                    └─ drop     → knowledge supersede <id>
... work ... (corrections happen in conversation; transcript keeps them)
wrap-up ──► session-save
              0. relay.sh turns   → user turns since last save
              1-3. handoff        → relay.sh save
              4. re-assert lessons that applied (incl. ones the turns revealed)
              5. new lessons/facts via relay-learn
                 → a lesson hitting sessions ≥ 3 shows up in tomorrow's Ready block
```

## 8. Should Relay become a Claude Code mod?

**Recommendation: no, not as a replacement; maybe later as an optional extra.**

Mods (Claude Code 2.1.286+, early access) are in-process TypeScript hooks. From
claude-reflect's working mod, they can react to session start, prompt submit and turn
completion, read the session's messages, inject into the system prompt, register commands,
render a band above the prompt with buttons, call a small model, read and write files, and
run processes. (This list comes from that mod's code, not from official docs; confirm
before building anything.)

What a mod would add for Relay:
- The graduation question as a **band with buttons** above the prompt, shown at startup
  before Jeremy types anything. That is a better version of §5.1 for Claude Code.
- Direct access to the session's messages, so Claude Code would not need the transcript
  path lookup.
- A save nudge on turn completion when a session has gone long without a handoff.

What it would cost:
- **Claude Code only.** Relay's main strength is working the same in Claude Code, Codex
  and Grok. Codex and Grok sessions would get none of it.
- **Early access.** claude-reflect documents an old session silently turning mods off for
  new sessions.
- **A TypeScript build** next to a zero-dependency bash tool, plus a second test stack.

If built later, the mod must be a UI layer only: every write goes through `relay.sh` via
process run, so the core invariant holds. Trigger to revisit: parts 1 and 2 have run for
3 weeks and ready lessons in Claude Code still go undecided.

## 9. Constraints

- Bash 3.2 (macOS) compatible, zero dependencies beyond what `relay.sh` already uses.
  JSONL parsing in `turns` should use `python3` when present and fall back to a line-based
  `sed`/`awk` extraction of user text; decide by measuring which is reliable on the three
  real transcript formats. (Builder's call; see §11.)
- All writes under the existing `mkdir` lock. `turns` takes no lock; it writes only the
  scratch file `.turns-pending`. `save` moves the cursor under its existing lock.
- `RELAY_FORMAT` bump if any stored format changes (`deferred_at`, `rule:` fields count).
- `bash bundle.sh` after edits; CI checks `dist/install.sh` is current.
- New tests follow the `tests/test_NN_*.sh` pattern; fixture transcripts (small, synthetic)
  for each harness live under `tests/fixtures/`.
- Curation freeze (§17): lifted by the measured exit condition; this design adds exactly two
  knowledge surfaces (`defer`, `graduate --rule`) and one read command (`turns`).

## 10. Rollout and how we know it worked

1. Build, test, merge. Reinstall in talelog first (`install.sh --detect`), since it holds
   all 7 ready lessons.
2. After 2 weeks in talelog:
   - Every ready lesson has a decision (graduated, deferred, or dropped). "Offer unanswered"
     no longer appears in history.
   - At least one lesson added or re-asserted where the handoff's Decisions or the lesson
     source traces back to a correction found in `turns`.
   - Jeremy does not describe the start-of-session question as a speed bump.
3. Then roll out to the other installs with the pending §17 rollout.

## 11. Left to the builder

- `turns` parsing approach (python3 vs pure shell) per §9, and exact filtering heuristics
  for system content per harness, based on the real files on this machine.
- Exact wording of the context-block instructions and skill step 0, kept short.
- How the Claude Code hook switches to JSON without breaking repos that run an older
  `relay.sh` (the hook script and `relay.sh` ship together in `.relay/`, so a version check
  in the hook is acceptable).
- Test breakdown and numbering.

## 12. Calls made by Claude (not decided by Jeremy)

- Ready block cap of 3 per session.
- Rule length cap of 240 characters, single line.
- `defer` as a new subcommand name; `supersede` reused for "drop".
- Ignoring the question counts as no answer, not as "not yet".
- Turns cap of 1,500 words; a turn over 80 words keeps its first 60 and last 20; pasted text kept as the user's words; acknowledgements counted, not shown.
- Grok gets turns without agent context, and no visible startup line.
- No mod now.
- Ready block has its own 600-word budget; at least one lesson always shown.
- Ready block only on a fresh start (startup, /clear), never on resume or compaction.
- `turns` takes `--harness`; two same-harness sessions in one folder at once are unsupported.
- The turns cursor moves on a successful save, not when `turns` runs; one line per transcript.
