#!/usr/bin/env bash
# test_53_load_hook_json.sh: hooks hand their session JSON to load. A real start (startup, clear,
# or no source) gets the Ready block and, for Claude Code and Codex, a visible systemMessage;
# compact/resume do not. The transcript path is noted for turns. Bad stdin never breaks load.
set -euo pipefail
cd "$(dirname "$0")"; . ./helper.sh
RELAY="$(cd .. && pwd)/relay.sh"; setup_tmp
L="$DIR/knowledge/lessons"
setfm() { sed -i.bak "s/^$2: .*/$2: $3/" "$1" && rm -f "$1.bak"; }
printf '## Summary\nthe handoff\n' | "$RELAY" save --dir "$DIR" --digest d
hook() { printf '%s' "$1" | env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID "$RELAY" load --dir "$DIR" --format "$2" --hook-json "$3"; }
isjson() { printf '%s' "$1" | python3 -m json.tool >/dev/null || { echo "FAIL: not JSON: $1"; exit 1; }; }

# nothing ready: claude format is JSON with the handoff and no systemMessage
out="$(hook '{"source":"startup"}' claude claude)"; isjson "$out"
assert_contains "$out" '"hookEventName":"SessionStart"'
assert_contains "$out" 'the handoff'
[ -z "$(printf '%s' "$out" | grep -F systemMessage || true)" ] || { echo "FAIL: systemMessage with nothing ready"; exit 1; }

"$RELAY" knowledge add --lesson --id r1 "when R, do S" --dir "$DIR" >/dev/null; setfm "$L/r1.md" sessions 3
out="$(hook '{"session_id":"s","source":"startup","transcript_path":"/t/a.jsonl"}' claude claude)"; isjson "$out"
assert_contains "$out" "\"systemMessage\":\"Relay: 1 lesson ready to become a rule. I'll ask before we start.\""
assert_contains "$out" "Ready to become rules"
assert_eq "$(cat "$DIR/.transcripts")" "$(printf 'claude\t/t/a.jsonl')"

out="$(hook '{"source":"clear"}' codex codex)"; isjson "$out"
assert_contains "$out" '"systemMessage":"Relay: 1 lesson'
assert_contains "$out" '"additionalContext"'

# no ready block on compact or resume
for src in compact resume; do
  out="$(hook "{\"source\":\"$src\"}" claude claude)"
  [ -z "$(printf '%s' "$out" | grep -F -e 'Ready to become rules' -e systemMessage || true)" ] || { echo "FAIL: ready on $src"; exit 1; }
  assert_contains "$out" 'the handoff'
done

# hook-json tolerates empty and garbage stdin (fresh, handoff printed, exit 0)
out="$(env -u CLAUDECODE "$RELAY" load --dir "$DIR" --format claude --hook-json claude </dev/null)"
assert_contains "$out" 'Ready to become rules'
out="$(hook 'not json at all' claude claude)"
assert_contains "$out" 'the handoff'

# two ready -> plural line; grok keeps its own format
"$RELAY" knowledge add --lesson --id r2 "when T, do U" --dir "$DIR" >/dev/null; setfm "$L/r2.md" sessions 4
assert_contains "$(hook '{"source":"startup"}' claude claude)" "Relay: 2 lessons ready to become rules. I'll ask before we start."
out="$(hook '{"source":"startup"}' grok grok)"; isjson "$out"
assert_contains "$out" 'Ready to become rules'

# transcript notes: deduped, newest 20 kept
hook '{"source":"startup","transcript_path":"/t/a.jsonl"}' claude claude >/dev/null
assert_eq "$(grep -c . "$DIR/.transcripts")" "1"
for i in $(seq 1 25); do hook "{\"source\":\"resume\",\"transcript_path\":\"/t/$i.jsonl\"}" claude claude >/dev/null; done
assert_eq "$(grep -c . "$DIR/.transcripts")" "20"
assert_eq "$(tail -n1 "$DIR/.transcripts")" "$(printf 'claude\t/t/25.jsonl')"

# CR and other control bytes in loaded text still give valid JSON
printf '## Summary\r\nred \033[31mtext\033[0m and a bell \007 here\r\n' | "$RELAY" save --dir "$DIR" --digest cr
for fmt in claude codex grok; do isjson "$(hook '{"source":"startup"}' $fmt $fmt)"; done

assert_exit 2 "$RELAY" load --dir "$DIR" --hook-json cursor
pass "load --hook-json: fresh-only Ready block, visible line, transcript notes, bad stdin tolerated"
