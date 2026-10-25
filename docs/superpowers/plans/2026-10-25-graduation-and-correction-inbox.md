# Graduation at Session Start + Correction Inbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Graduation-ready lessons are asked about at the start of a fresh session and graduate as one-line rules. At save time the agent reads the user's own turns back from the harness transcript, so corrections feed lessons.

**Architecture:** Everything lands in `relay.sh` (the deterministic core) plus thin adapter changes. `load` gains a Ready block and hook-aware JSON output. `knowledge` gains `defer` and `graduate --rule`. A new read-only `turns` command, an embedded python3 program, locates the current transcript and prints the user's turns. `save` moves the turns cursor. The skills change wording only.

**Tech Stack:** bash 3.2+ (macOS default), awk/sed, python3 (only inside `turns`), the zero-dependency test harness in `tests/`.

**Spec:** `docs/superpowers/specs/2026-10-25-graduation-and-correction-inbox-design.md`

## Global Constraints

- `relay.sh` stays one file, `set -euo pipefail`, bash 3.2 compatible (no associative arrays, no `${x,,}`, no `mapfile`).
- Every write to knowledge, AGENTS.md, history, or `.turns-cursor` happens under `_lock`/`_unlock`. The only unlocked writes are the scratch files `.session-log/.transcripts` (written by `load`) and `.session-log/.turns-pending` (written by `turns`).
- Nothing from a transcript is written to disk. `turns` prints only. `.transcripts`, `.turns-pending`, and `.turns-cursor` hold paths and timestamps only.
- python3 is used only by `turns`, through `RELAY_PYTHON="${RELAY_PYTHON:-python3}"`. If it is missing, `turns` prints `relay: turns needs python3; save from memory` and exits 0.
- Values (copy exactly): `RELAY_GRADUATE_AT` default 3; `RELAY_READY_MAX` default 3; `RELAY_READY_CAP` default 600 (words); rule = one line, 1 to 240 characters; `RELAY_TURNS_CAP` default 1500 (words); a turn over 80 words shows its first 60 words, ` … `, and its last 20; agent context = the last 25 words of the assistant text before the turn; `.transcripts` and `.turns-cursor` are trimmed to their newest 20 lines.
- No `RELAY_FORMAT` bump. The new frontmatter fields (`deferred_at`, `rule`) are tolerated by an older `relay.sh` because `_fm_set` rewrites only keys that already exist and keeps the rest.
- After editing `relay.sh`, `install.sh`, or `adapters/`, run `bash bundle.sh` before committing (CI diffs `dist/install.sh`).
- Tests are `tests/test_NN_name.sh` using `tests/helper.sh`. The full suite is `bash tests/run.sh && bash tests/smoke-compact.sh`.
- Every test that runs `turns` or `load --hook-json` must run with `env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID HOME="$TMP/home"`. The suite itself usually runs inside Claude Code.
- Copy in documents written for Jeremy uses dashes only inside compound words.

## Review Focus

1. **Wispr dictation arrives wrapped in `<pasted_content id="…">…</pasted_content>` tags** inside a user turn. It must be kept as the user's words with the tags removed, not dropped as system text. Test in Task 5: `turns keeps pasted dictation`.
2. **Two Claude Code windows in one repo.** `CLAUDE_CODE_SESSION_ID` is present in the agent's shell, so `turns` must pick `<id>.jsonl` even when another transcript was modified more recently. Test in Task 5: `turns picks the session from CLAUDE_CODE_SESSION_ID`.
3. **The hook gets no stdin, empty stdin, or invalid JSON.** `load --hook-json` must still print the handoff, never hang, and treat the start as fresh. Test in Task 4: `hook-json tolerates empty and garbage stdin`.
4. **A rule containing quotes, backticks, `$(…)`, or `&`** must land in AGENTS.md byte for byte (it reaches awk through a file, never `-v`). Test in Task 2: `graduate --rule writes shell-hostile text verbatim`.
5. **Compaction and resume.** Codex fires the hook on `compact` and Claude Code on `compact`/`resume`. On those events the Ready block and the visible line must not appear. Test in Task 4: `no ready block on compact or resume`.

---

### Task 1: `knowledge defer` and defer-aware readiness

**Files:**
- Modify: `relay.sh` (`_fm_set` neighbourhood; `_k_add_lesson` ready message; `cmd_knowledge` dispatch)
- Test: `tests/test_50_knowledge_defer.sh`

**Interfaces:**
- Produces: `_fm_put FILE KEY VALUE` (sets the key if present, else inserts `KEY: VALUE` before the closing `---` of the frontmatter); `_is_ready FILE` (exit 0 when `sessions >= RELAY_GRADUATE_AT` and (`deferred_at` empty or `sessions > deferred_at`)); `k_defer ID`.

- [ ] **Step 1: Write the failing test** `test_50_knowledge_defer.sh`:
  - Add lesson `x` and force `sessions: 3` with `sed -i.bak` on its file. `knowledge defer x` prints `deferred: x (now sessions:3; comes back once re-asserted on a later day)`, and the file has `deferred_at: 3`.
  - `knowledge defer missing` exits 1 with `relay: no active lesson: missing` on stderr.
  - Re-asserting `x` on the same day does not print `graduation-ready`.
  - Set `last_seen: 2000-01-01`, then re-assert: sessions goes to 4, and the output contains `→ graduation-ready (sessions:4 ≥ 3): it will be asked about at the next session start`.
  - A non-deferred lesson reaching sessions 3 prints the same new wording.
  - The old wording `propose 'relay knowledge graduate` no longer appears in `relay.sh`.
- [ ] **Step 2: Run** `bash tests/test_50_knowledge_defer.sh`. Expected: FAIL (`unknown knowledge subcommand` or a missing message).
- [ ] **Step 3: Implement** `_fm_put`, `_is_ready`, and `k_defer` (lock, `_fm_put deferred_at <sessions>`, `_kindex`, unlock). Wire `defer)` into `cmd_knowledge`, and add `defer` to the knowledge usage text. In `_k_add_lesson`, replace the ready echo with `_is_ready "$f" && echo "  → graduation-ready (sessions:$sess ≥ $RELAY_GRADUATE_AT): it will be asked about at the next session start"`, keeping `return 0` last.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass (update `test_11`/`test_16` only if they assert the old wording).
- [ ] **Step 5: Commit** `feat(relay): knowledge defer; graduation-ready respects deferral`.

### Task 2: `graduate --rule` and `why` for graduated lessons

**Files:**
- Modify: `relay.sh` (`k_graduate`, `k_why`)
- Test: `tests/test_51_graduate_rule.sh`

**Interfaces:**
- Consumes: `_fm_put` (Task 1).
- Produces: `knowledge graduate <id> [--rule TEXT|-]`. With `--rule`, the instruction-file block body is exactly `- <rule> (why: relay knowledge why <id>)`, and the graduated lesson gets `rule: <rule>`. Without it, behaviour is unchanged.

- [ ] **Step 1: Write the failing test** `test_51_graduate_rule.sh` (run in `$TMP` with an `AGENTS.md`):
  - `graduate x --rule "Never edit a running script."` writes the lines `<!-- relay:learned:x -->`, `- Never edit a running script. (why: relay knowledge why x)`, and `<!-- /relay:learned:x -->`. The lesson body text is absent from AGENTS.md. `lessons/graduated/x.md` has `rule: Never edit a running script.`
  - Stdin form `graduate y --rule - <<'R'` with the text ``Use "$(pwd)" & `git` 'carefully'`` puts that exact text in AGENTS.md (**Review Focus 4**: `graduate --rule writes shell-hostile text verbatim`).
  - A two-line rule, an empty rule, and a 241-character rule each exit 2 with `relay: --rule must be one line of 1 to 240 characters`. The lesson stays active and AGENTS.md is unchanged.
  - `graduate z` with no `--rule` still copies the body (regression).
  - `knowledge why x` after graduation prints `--- entry ---` and the graduated file.
- [ ] **Step 2: Run** the test. Expected: FAIL.
- [ ] **Step 3: Implement.** Parse `id` and an optional `--rule VALUE` / `--rule -` (stdin) in `k_graduate`. Validate before taking the lock: no newline, and length 1 to 240 counted with `printf %s "$rule" | wc -m`. Pass the composed line to `_block_upsert`. In `k_why`, extend the search to `lessons/graduated`.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(relay): graduate --rule writes a one-line rule; why finds graduated lessons`.

### Task 3: Ready block in `load`

**Files:**
- Modify: `relay.sh` (`main` arg parsing, `cmd_load`, `_load_knowledge` lessons section, new `_load_ready`)
- Test: `tests/test_52_load_ready.sh`

**Interfaces:**
- Consumes: `_is_ready` (Task 1).
- Produces: `load --fresh`. `_load_ready` prints the block and sets global `READY_IDS` (space-separated ids shown) and `READY_SHOWN` (count). `_load_knowledge` skips ids in `READY_IDS`. Task 4 uses `READY_SHOWN` for the visible line.

Exact block copy (the lines after the heading are one paragraph):

```
## Ready to become rules (ask before starting work)
These lessons have come up on 3+ separate days. Before acting on the user's first message, ask once about each: propose a one-line rule (240 characters max) and offer yes / edit / not yet / drop. Yes or edit: relay knowledge graduate <id> --rule - (rule on stdin). Not yet: relay knowledge defer <id>. Drop: relay knowledge supersede <id>. Use a multiple-choice question tool if you have one, otherwise a numbered list. If the user skips the question, record nothing.
- `<id>` (sessions:<n>): <body on one line>
(+<k> more ready; they come up next session)
```

The ready lessons are ranked by `sessions` desc, then `last_seen` recency. Fill greedily: keep adding while `shown < RELAY_READY_MAX` and the words still fit `RELAY_READY_CAP`, and always show the first. The `(+k more…)` line appears only when k > 0. The block goes right after the "Last saved" line (and any format warning), before the handoff.

- [ ] **Step 1: Write the failing test** `test_52_load_ready.sh`:
  - Five lessons at sessions 6, 5, 4, 3, 1. `load --fresh` shows the heading above `## Summary`, the ids for 6/5/4 in that order, and `(+1 more ready; they come up next session)`. The `## What this repo knows — lessons` list does not contain those three ids but does contain the sessions-1 lesson.
  - `load` without `--fresh` has no Ready heading, and all lessons appear in the normal list.
  - Budget: three ready lessons of 250 words each, so only the first is shown, with `(+2 more ready…)`.
  - A deferred lesson (`deferred_at` equal to its sessions) is not shown. After raising its sessions by one, it is shown.
  - With no ready lessons, `load --fresh` output equals `load` output byte for byte.
- [ ] **Step 2: Run** the test. Expected: FAIL (`unknown arg --fresh`).
- [ ] **Step 3: Implement** `--fresh` in `main` (passed as the second arg to `cmd_load`), `_load_ready`, and the `READY_IDS` exclusion in the lessons loop of `_load_knowledge`. Add `RELAY_READY_MAX`/`RELAY_READY_CAP` defaults at the top, and update `usage`.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(relay): Ready block at fresh session start`.

### Task 4: Hook-aware `load` (JSON input and output, visible line, transcript note)

**Files:**
- Modify: `relay.sh` (`main`, `cmd_load`), `adapters/claude-code/relay-session-start.sh`, `adapters/codex/relay-session-start.sh`, `adapters/grok/relay-session-start.sh`
- Test: `tests/test_53_load_hook_json.sh`; update `tests/test_07_cc_adapter.sh`, `tests/test_08_codex_adapter.sh`

**Interfaces:**
- Consumes: `READY_SHOWN` and `--fresh` semantics (Task 3).
- Produces: `load --hook-json HARNESS` (HARNESS ∈ claude|codex|grok). It reads hook JSON from stdin when stdin is not a tty, extracting `source` and `transcript_path` with `sed`. Fresh means `source` ∈ {startup, clear} or `source` empty. When `transcript_path` is non-empty, it appends `HARNESS<TAB>path` to `.session-log/.transcripts` (deduped, newest 20 kept). New `--format claude` prints `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"}}`. For `claude` and `codex` formats, when `READY_SHOWN > 0`, a top-level `"systemMessage"` is added: `Relay: 2 lessons ready to become rules. I'll ask before we start.` (singular: `Relay: 1 lesson ready to become a rule. I'll ask before we start.`). Task 5 reads `.transcripts`.
- Hook scripts become: CC `… load --dir … --format claude --hook-json claude`; Codex `… --format codex --hook-json codex`; Grok `… --format grok --hook-json grok`. Each keeps stdin attached (no redirect) and keeps `|| true; exit 0`.

- [ ] **Step 1: Write the failing test** `test_53_load_hook_json.sh`:
  - With one ready lesson, `printf '{"source":"startup","transcript_path":"/t/a.jsonl"}' | relay.sh load --format claude --hook-json claude` outputs valid JSON (check with `python3 -m json.tool`). It contains `"systemMessage":"Relay: 1 lesson ready to become a rule. I'll ask before we start."` and an additionalContext with the Ready heading. `.transcripts` contains `claude	/t/a.jsonl`.
  - `source` of `compact` or `resume` gives no systemMessage and no Ready heading (**Review Focus 5**: `no ready block on compact or resume`).
  - `</dev/null` input and `printf 'not json'` input each print the handoff with exit 0, treated as fresh (**Review Focus 3**: `hook-json tolerates empty and garbage stdin`).
  - With no ready lessons, there is no `systemMessage` key.
  - Recording the same path twice leaves one line. 25 distinct paths leave 20 lines.
  - test_07: the CC hook output is now JSON and contains `hello from cc` inside additionalContext. test_08: unchanged assertions still pass.
- [ ] **Step 2: Run** the tests. Expected: FAIL.
- [ ] **Step 3: Implement** in `relay.sh` and the three hook scripts. `_json_escape` is reused for both strings.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(adapters): hooks pass session JSON to load; Claude Code emits JSON with a visible ready line`.

### Task 5: `turns` for Claude Code

**Files:**
- Modify: `relay.sh` (`main` dispatch for `turns`, `--harness` arg, new `cmd_turns`, embedded python program `_turns_py`)
- Create: `tests/fixtures/turns/claude.jsonl`
- Test: `tests/test_54_turns_claude.sh`

**Interfaces:**
- Consumes: `.session-log/.transcripts` (Task 4).
- Produces: `relay.sh turns [--dir DIR] [--harness auto|claude|codex|grok]` (default `auto`). It always exits 0. On success it writes `.session-log/.turns-pending` as `<transcript path><TAB><newest turn timestamp>`. Task 6 extends harness support. Task 7 consumes `.turns-pending` and `.turns-cursor`.
- `cmd_turns` runs `"$RELAY_PYTHON" - <harness> <repo root> <data dir> <<'PY' … PY`. The repo root is `$(cd "$(dirname "$DATA")" && pwd -P)`. The python program owns locating, parsing, formatting, and writing `.turns-pending`. It reads `HOME`, `CLAUDE_CODE_SESSION_ID`, `RELAY_TURNS_CAP` from the environment. Keep the python in relay.sh (single-file distribution). It must not contain a line equal to `RELAY_EOF`.

Claude Code rules:
- **Locate:** if `CLAUDE_CODE_SESSION_ID` is set, use the `.transcripts` claude path whose basename is `<id>.jsonl`, else `$HOME/.claude/projects/*/<id>.jsonl`. Otherwise use the most recently modified existing claude path in `.transcripts`. Otherwise use the newest `*.jsonl` in `$HOME/.claude/projects/<root with every non-alphanumeric char replaced by ->/`.
- **User turn:** a record with `type == "user"`, not `isMeta`, not `isSidechain`, whose `message.content` is a string or has `text` parts. Text starting with `<` is skipped, *except* text whose leading tag is `<pasted_content`. For those, remove the `<pasted_content …>`/`</pasted_content>` tags and keep the inner text. Strip a leading `[Image #N]`.
- **Rejection:** a `tool_result` part with `is_error: true` whose text contains `the user said:`. Show `you rejected a tool call: "<text after it>"`. A rejection without a reason shows `you rejected a tool call`.
- **Agent context:** the text parts of the last `type == "assistant"` record (not a sidechain) before the turn; last 25 words.
- **Acknowledgement:** after lowercasing and stripping punctuation, the whole turn is one of: ok, okay, k, yes, yep, yeah, sure, go ahead, continue, proceed, do it, perfect, great, thanks, thank you, sounds good, looks good. Counted, not shown.
- **Since:** turns whose ISO `timestamp` is greater than this transcript's line in `.turns-cursor`. If there is no line, use all turns.

Output copy (times are local `HH:MM`):

```
## Your turns this session (since <HH:MM of cursor | session start>; <n> turns, <a> acknowledgements not shown[, <d> older turns dropped])
(transcript: <path>)
1. [14:05] agent said: "…<25 words>" → you: "<turn>"
2. [14:12] you rejected a tool call: "<reason>"
```

Fallback lines, exit 0: `relay: no transcript found for this session; save from memory` · `relay: no new turns since the last save` · `relay: turns needs python3; save from memory` (when `$RELAY_PYTHON` is not runnable).

- [ ] **Step 1: Write the fixture.** `claude.jsonl` holds about 12 records with synthetic text covering: a plain user turn after assistant text; an `isMeta` turn; a `<command-name>` turn; a sidechain user turn; a `<pasted_content id="a1">okay let's try this instead, no border</pasted_content>` turn; a rejection with `the user said:\ndon't touch the theme file`; two acknowledgements ("ok", "Perfect!"); a 100-word turn; tool_use/thinking-only assistant records.
- [ ] **Step 2: Write the failing test** `test_54_turns_claude.sh`, copying the fixture to `$HOME/.claude/projects/<encoded>/s1.jsonl` and recording it in `.transcripts`:
  - The output has the header with `2 acknowledgements not shown`.
  - `turns keeps pasted dictation`: `you: "okay let's try this instead, no border"` (**Review Focus 1**).
  - The rejection line appears. The meta, command, and sidechain texts are absent.
  - The 100-word turn shows ` … ` and is under 85 words.
  - The agent context is quoted and at most 25 words.
  - `.turns-pending` has `<path>\t<last user timestamp>`.
  - `turns picks the session from CLAUDE_CODE_SESSION_ID`: a second transcript `s2.jsonl` is touched newer. With `CLAUDE_CODE_SESSION_ID=s1`, the output's `(transcript: …s1.jsonl)` (**Review Focus 2**). Without it, s2 is picked.
  - Empty `.transcripts` and no projects dir prints the no-transcript line, exit 0.
  - `RELAY_PYTHON=/nonexistent` prints the python3 line, exit 0.
  - `RELAY_TURNS_CAP=40` gives a header containing `older turns dropped`, and the newest turn is still present.
- [ ] **Step 3: Run** the test. Expected: FAIL.
- [ ] **Step 4: Implement** `cmd_turns` and `_turns_py`. Add `turns` to `main`'s dispatch and usage.
- [ ] **Step 5: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 6: Commit** `feat(relay): turns reads the user's turns from the Claude Code transcript`.

### Task 6: `turns` for Codex and Grok, plus `auto`

**Files:**
- Modify: `relay.sh` (`_turns_py`)
- Create: `tests/fixtures/turns/codex.jsonl`, `tests/fixtures/turns/grok_prompt_history.jsonl`
- Test: `tests/test_55_turns_codex_grok.sh`

**Interfaces:**
- Consumes: Task 5's program and output format.
- **Codex:** locate the newest existing codex path in `.transcripts`. Otherwise use the newest `rollout-*.jsonl` under `$HOME/.codex/sessions` modified in the last 2 days whose first `session_meta` payload `cwd` equals the repo root. User turns are `event_msg` records with `payload.type == "user_message"` (text = `payload.message`). Agent context comes from `response_item` records with `payload.role == "assistant"`, from their `output_text` parts.
- **Grok:** the file is `${GROK_HOME:-$HOME/.grok}/sessions/<urllib.parse.quote(root, safe='')>/prompt_history.jsonl`. Use the `session_id` of the last line, and turns are lines with that `session_id` and `is_bash` false (text = `prompt`). There is no agent context, so lines read `you: "…"`.
- **auto:** `CLAUDECODE=1` means claude. Any env var starting `CODEX_` means codex. Any env var starting `GROK_` means grok. Otherwise try all three and use the transcript with the newest modification time.

- [ ] **Step 1: Write fixtures.** Codex: a `session_meta` with `cwd` = placeholder `__ROOT__` (the test seds in the real root), an `<environment_context>` `response_item` user message (must be ignored), two `user_message` events, and assistant `output_text`. Grok: lines from two session ids, with one `is_bash: true` line in the newest session.
- [ ] **Step 2: Write the failing test** `test_55_turns_codex_grok.sh`:
  - `--harness codex` shows both user_message texts and no `environment_context`, with an agent context.
  - `--harness grok` shows only the newest session's non-bash prompts, with no `agent said`.
  - `auto` with `CODEX_THREAD_ID=x` picks codex. With `GROK_HOME="$HOME/.grok"`, it picks grok. With none set, it picks the newest-modified file.
  - A Codex rollout whose `cwd` is a different repo is ignored, so the no-transcript line is printed.
- [ ] **Step 3: Run** the test. Expected: FAIL.
- [ ] **Step 4: Implement** in `_turns_py`.
- [ ] **Step 5: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 6: Commit** `feat(relay): turns supports Codex and Grok transcripts and auto-detects the harness`.

### Task 7: `save` moves the turns cursor

**Files:**
- Modify: `relay.sh` (`cmd_save`, new `_turns_commit`)
- Test: `tests/test_56_turns_cursor.sh`

**Interfaces:**
- Consumes: `.turns-pending` (Task 5).
- Produces: `_turns_commit`, called inside `cmd_save`'s lock after `_index_update`. If `.turns-pending` exists, it replaces or appends that path's line in `.turns-cursor`, keeps the newest 20 lines, and removes `.turns-pending`.

- [ ] **Step 1: Write the failing test** `test_56_turns_cursor.sh` (Claude fixture from Task 5):
  - `turns` then `save` creates `.turns-cursor` with the path and timestamp, and `.turns-pending` is gone. A second `turns` prints `relay: no new turns since the last save`.
  - Append one new user record, and `turns` shows only it, with a header `since HH:MM`.
  - Abandoned save: `turns` twice with no `save` shows the same turns both times, and the cursor is unchanged.
  - Two transcripts each saved once give two cursor lines.
- [ ] **Step 2: Run** the test. Expected: FAIL.
- [ ] **Step 3: Implement** `_turns_commit` and call it.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(relay): save advances the turns cursor`.

### Task 8: Skills and instruction blocks

**Files:**
- Modify: `adapters/skills/session-save/SKILL.md`, `adapters/codex/skills/session-save/SKILL.md`, `adapters/opencode/commands/session-save.md`, `adapters/skills/relay-learn/SKILL.md`, `adapters/codex/skills/relay-learn/SKILL.md`, `adapters/opencode/commands/relay-learn.md`, `adapters/skills/relay-compact/SKILL.md`, `adapters/codex/skills/relay-compact/SKILL.md`, `adapters/opencode/commands/relay-compact.md`, `adapters/{claude-code,codex,grok,cursor,opencode}/AGENTS.relay.md`
- Test: update `tests/test_46_skill_guidance.sh`

**Interfaces:**
- Consumes: `turns --harness`, `graduate --rule -`, `defer` (Tasks 1, 2, 5, 6).

Changes (exact sentences where quoted):
- **session-save, new step 0, before authoring.** Run `"$PWD/.relay/relay.sh" turns --dir "$PWD/.session-log" --harness <h>`, where `<h>` is `auto` in `adapters/skills` and `codex` in the Codex copy. OpenCode's copy omits step 0 (no transcript). Then the spec §6.4 paragraph, verbatim, with the heading `Read your turns first.`
- **session-save step 5 and relay-learn.** Replace the graduation offer with: `If the tool says a lesson is graduation-ready, tell the user it will be asked about at the next session start. Do not offer graduation now.`
- **relay-compact.** Graduation proposals use `knowledge graduate <id> --rule -` with a one-line rule drafted from the lesson, still human-gated.
- **AGENTS.relay.md (all five).** Replace `and surface any graduation-ready lesson for the user to approve.` with `Graduation-ready lessons are asked about at session start (the Ready block); never graduate without the user's yes.`
- **test_46 new assertions.** Each session-save file except OpenCode contains `relay.sh" turns` and `Read your turns first.` No skill or AGENTS block contains `offer graduation in one line` or `surface any graduation-ready lesson`. Each relay-compact contains `--rule -`.

- [ ] **Step 1: Update test_46** with the assertions above.
- [ ] **Step 2: Run** it. Expected: FAIL.
- [ ] **Step 3: Edit** the files listed.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `docs(adapters): save reads turns first; graduation moves to session start`.

### Task 9: Docs, bundle, and live verification

**Files:**
- Modify: `README.md` (Use, Lesson lifecycle, Command surface), `docs/design-spec.md` (§7 load: Ready block and hook JSON; new subsection under §6 for `turns`; §17: the curation freeze lifted on 2026-10-25 by the measured exit condition (talelog: 12 lessons at sessions ≥ 2), Cursor/OpenCode note unchanged), `dist/install.sh` (regenerated)

- [ ] **Step 1: Update** README and design-spec to match Tasks 1 to 8. Write no new claims beyond the spec.
- [ ] **Step 2: Run** `bash bundle.sh && bash tests/run.sh && bash tests/smoke-compact.sh`. Expected: all pass, and `git status` shows `dist/install.sh` changed.
- [ ] **Step 3: Live check in Claude Code.** Make a scratch repo, run `bash <repo>/install.sh --detect` there, add one lesson, and force `sessions: 3`. Start `claude` in it. Expected: the UI shows `Relay: 1 lesson ready to become a rule…`, and the agent's first reply asks the question. In that session, run `.relay/relay.sh turns --dir .session-log` from the agent's shell. Expected: the header names this session's transcript, and your first prompt is listed. Record the result in the PR body. If the systemMessage does not render, note it. The context block still works.
- [ ] **Step 4: Live check in Codex** (the same scratch repo, `/hooks` trust once). Expected: the Ready block appears in context, and `turns --harness codex` lists your prompt. If the Codex hook stdin has no `transcript_path`, confirm the fallback scan found the rollout. Record the result.
- [ ] **Step 5: Commit** `docs(relay): document Ready block, graduate --rule, defer, and turns; lift curation freeze`, then push the branch and open the PR (CI must be green on Ubuntu and macOS).

After merge (not part of this plan's tasks): reinstall in talelog with `install.sh --detect`, commit `.relay/` there, and start the two-week check from spec §10.
