emit_relay() { cat <<'RELAY_EOF'
#!/usr/bin/env bash
# relay.sh — deterministic session-handoff helper
set -euo pipefail

RELAY_WINDOW=10
RELAY_STALE_DAYS=3
RELAY_WORD_CAP=800
RELAY_LOCK_TIMEOUT=30

usage() {
  echo "usage: relay.sh {load|save} [--dir DIR] [--format text|codex] [--digest STR]" >&2
}

main() {
  local cmd="${1:-}"; [ $# -gt 0 ] && shift || true
  DATA="${RELAY_DIR:-$PWD/.session-log}"
  local format="text" digest=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) DATA="$2"; shift 2;;
      --format) format="$2"; shift 2;;
      --digest) digest="$2"; shift 2;;
      *) echo "relay: unknown arg $1" >&2; usage; return 2;;
    esac
  done
  case "$cmd" in
    load) cmd_load "$format";;
    save) cmd_save "$digest";;
    *) usage; return 2;;
  esac
}

to_epoch() { date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null; }

_index_update() {
  local date="$1" digest="$2" idx="$DATA/index.md" tmp
  tmp="$(mktemp)"
  printf '# Session index — last %s days\n' "$RELAY_WINDOW" > "$tmp"
  printf -- '- %s — %s → history/%s.md\n' "$date" "$digest" "$date" >> "$tmp"
  if [ -f "$idx" ]; then
    grep '^- ' "$idx" 2>/dev/null | grep -v "^- $date " >> "$tmp" || true
  fi
  { sed -n '1p' "$tmp"; grep '^- ' "$tmp" | head -n "$RELAY_WINDOW"; } > "$idx"
  rm -f "$tmp"
}

_unlock() { [ -n "${DATA:-}" ] && rm -rf "$DATA/.lock" 2>/dev/null || true; }

_lock() {
  local lock="$DATA/.lock" waited=0 pid ts now
  mkdir -p "$DATA"
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -f "$lock/info" ]; then
      pid="$(sed -n '1p' "$lock/info" 2>/dev/null || true)"
      ts="$(sed -n '2p' "$lock/info" 2>/dev/null || printf 0)"
      now="$(date +%s)"
      if { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; } \
         || [ "$(( now - ${ts:-0} ))" -gt "$RELAY_LOCK_TIMEOUT" ]; then
        rm -rf "$lock"; continue
      fi
    fi
    waited=$(( waited + 1 ))
    [ "$waited" -gt "$RELAY_LOCK_TIMEOUT" ] && { echo "relay: lock wait timeout" >&2; return 1; }
    sleep 1
  done
  printf '%s\n%s\n' "$$" "$(date +%s)" > "$lock/info"
  trap _unlock EXIT
}

_prune() {
  local n=0 f
  for f in $(ls -1 "$DATA/history"/*.md 2>/dev/null | sort -r); do
    n=$((n+1))
    [ "$n" -gt "$RELAY_WINDOW" ] && rm -f "$f"
  done
  return 0
}

_json_escape() {
  awk 'BEGIN{ORS=""}
       { gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t");
         if (NR>1) printf "\\n"; printf "%s", $0 }'
}

cmd_load() {
  local format="${1:-text}" latest="$DATA/latest.md" idx="$DATA/index.md"
  [ -f "$latest" ] || return 0
  local sdate today se st days n out
  sdate="$(sed -n 's/^date:[[:space:]]*//p' "$latest" | head -n1)"
  today="$(date +%F)"; days=0
  if [ -n "$sdate" ]; then
    se="$(to_epoch "$sdate" 2>/dev/null || printf 0)"
    st="$(to_epoch "$today" 2>/dev/null || printf 0)"
    [ "${se:-0}" -gt 0 ] && [ "${st:-0}" -gt 0 ] && days=$(( (st - se) / 86400 ))
  fi
  if [ "$days" -le 0 ]; then
    out="Last saved: ${sdate:-unknown} (today)"$'\n\n'
  elif [ "$days" -gt "$RELAY_STALE_DAYS" ]; then
    out="⚠ Last saved: $sdate — $days days ago"$'\n\n'
  else
    out="Last saved: $sdate ($days day(s) ago)"$'\n\n'
  fi
  n="$(wc -w < "$latest" | tr -d ' ')"
  if [ "${n:-0}" -gt "$RELAY_WORD_CAP" ]; then
    out="$out$(awk -v cap="$RELAY_WORD_CAP" 'BEGIN{c=0}{c+=NF;print} c>=cap{print "\n…[truncated — open .session-log/latest.md for the full handoff]"; exit}' "$latest")"
  else
    out="$out$(cat "$latest")"
  fi
  [ -f "$idx" ] && out="$out"$'\n\n'"$(cat "$idx")"
  out="$out"$'\n\nOpen .session-log/history/<date>.md for the full detail of an earlier day.'
  if [ "$format" = "codex" ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","systemMessage":"%s"}}\n' \
      "$(printf '%s' "$out" | _json_escape)"
  else
    printf '%s\n' "$out"
  fi
}

cmd_save() {
  local digest="$1" body date today fm handoff n=0
  body="$(cat)"
  date="$(date +%F)"
  _lock || return 1            # acquire AFTER reading stdin (authoring is lock-free)
  mkdir -p "$DATA/history"
  today="$DATA/history/$date.md"
  if [ -f "$today" ]; then
    n=$(grep -c '^date:' "$today" 2>/dev/null) || n=0
  fi
  local sess=$(( n + 1 ))
  fm="$(printf -- '---\ndate: %s\nsession: %s\ndigest: "%s"\n---' "$date" "$sess" "$digest")"
  handoff="$(printf '%s\n\n%s' "$fm" "$body")"
  if [ -f "$today" ]; then
    printf '\n\n---\n\n%s\n' "$handoff" >> "$today"
  else
    printf '%s\n' "$handoff" > "$today"
  fi
  printf '%s\n' "$handoff" > "$DATA/latest.md"
  _index_update "$date" "$digest"
  _prune
  _unlock
}

main "$@"

RELAY_EOF
}

emit_adapters() {
  mkdir -p ".relay/adapters/claude-code"
  emit__adapters_claude_code_CLAUDE_relay_md > ".relay/adapters/claude-code/CLAUDE.relay.md"
  mkdir -p ".relay/adapters/claude-code/commands"
  emit__adapters_claude_code_commands_session_save_md > ".relay/adapters/claude-code/commands/session-save.md"
  mkdir -p ".relay/adapters/claude-code"
  emit__adapters_claude_code_relay_session_start_sh > ".relay/adapters/claude-code/relay-session-start.sh"
  mkdir -p ".relay/adapters/codex"
  emit__adapters_codex_AGENTS_relay_md > ".relay/adapters/codex/AGENTS.relay.md"
  mkdir -p ".relay/adapters/codex"
  emit__adapters_codex_hooks_relay_toml > ".relay/adapters/codex/hooks.relay.toml"
  mkdir -p ".relay/adapters/codex"
  emit__adapters_codex_relay_session_start_sh > ".relay/adapters/codex/relay-session-start.sh"
  mkdir -p ".relay/adapters/codex/skills/session-save"
  emit__adapters_codex_skills_session_save_SKILL_md > ".relay/adapters/codex/skills/session-save/SKILL.md"
}

emit__adapters_claude_code_CLAUDE_relay_md() { cat <<'RELAY_EOF'
<!-- adapters/claude-code/CLAUDE.relay.md -->
## Relay — session handoff (L2)
When the user signals the session is wrapping up ("done for today", "let's
continue tomorrow", or a task completes and we're winding down), run
`/session-save` to persist a Relay handoff. If unsure the session is ending,
offer it in one line.

RELAY_EOF
}

emit__adapters_claude_code_commands_session_save_md() { cat <<'RELAY_EOF'
<!-- adapters/claude-code/commands/session-save.md -->
---
description: Save a Relay handoff so the next session can pick up where you left off
---
Persist a Relay handoff for the next agent.

1. Author the six sections as concise markdown — `## Summary`, `## Changed`,
   `## Decisions`, `## Next`, `## Watch out`, `## Open questions` — naming real
   files/paths and dated facts. Compose a one-line digest.
2. Persist it. The script owns all file writes, rotation, and locking:

   ```bash
   printf '%s\n' '<<the six sections as markdown>>' \
     | "$CLAUDE_PROJECT_DIR/.relay/relay.sh" save \
         --dir "$CLAUDE_PROJECT_DIR/.session-log" \
         --digest '<<one-line digest>>'
   ```
3. Reply: "Handoff saved for the next session."

RELAY_EOF
}

emit__adapters_claude_code_relay_session_start_sh() { cat <<'RELAY_EOF'
#!/usr/bin/env bash
# Claude Code SessionStart hook → prints the Relay handoff (stdout is injected into context).
set -euo pipefail
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -x "$ROOT/.relay/relay.sh" ] || exit 0
"$ROOT/.relay/relay.sh" load --dir "$ROOT/.session-log" 2>/dev/null || true
exit 0

RELAY_EOF
}

emit__adapters_codex_AGENTS_relay_md() { cat <<'RELAY_EOF'
<!-- adapters/codex/AGENTS.relay.md -->
## Relay — session handoff (L2 + load fallback)
At the START of a session, read `.session-log/latest.md` and `.session-log/index.md`
first — they are the last agent's handoff. When wrapping up ("done for today" /
"continue tomorrow"), run `$session-save` to persist a new handoff; offer it if unsure.

RELAY_EOF
}

emit__adapters_codex_hooks_relay_toml() { cat <<'RELAY_EOF'
# adapters/codex/hooks.relay.toml — merge into .codex/config.toml
[[hooks.SessionStart]]
command = [".relay/adapters/codex/relay-session-start.sh"]

RELAY_EOF
}

emit__adapters_codex_relay_session_start_sh() { cat <<'RELAY_EOF'
#!/usr/bin/env bash
# Codex SessionStart hook → emits {systemMessage:<handoff>} JSON.
set -euo pipefail
ROOT="${CODEX_PROJECT_DIR:-$PWD}"
[ -x "$ROOT/.relay/relay.sh" ] || exit 0
"$ROOT/.relay/relay.sh" load --dir "$ROOT/.session-log" --format codex 2>/dev/null || true
exit 0

RELAY_EOF
}

emit__adapters_codex_skills_session_save_SKILL_md() { cat <<'RELAY_EOF'
<!-- adapters/codex/skills/session-save/SKILL.md -->
---
name: session-save
description: Save a Relay handoff for the next Codex session
---
Persist a Relay handoff for the next agent.

1. Author the six sections (`## Summary`, `## Changed`, `## Decisions`, `## Next`,
   `## Watch out`, `## Open questions`) and a one-line digest.
2. Run:

   ```bash
   printf '%s\n' '<<six sections>>' \
     | "${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" save \
         --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log" \
         --digest '<<one-line digest>>'
   ```
3. Reply: "Handoff saved for the next session."

RELAY_EOF
}

#!/usr/bin/env bash
# install.sh — lay Relay into the current repo. (Bundled release embeds sources; --from uses a source tree.)
set -euo pipefail
MARK="# >>> relay >>>"
FROM=""; [ "${1:-}" = "--from" ] && FROM="$2"

copy_tool() {
  mkdir -p .relay
  if [ -n "$FROM" ]; then
    cp "$FROM/relay.sh" .relay/relay.sh
    cp -R "$FROM/adapters" .relay/adapters
  else
    emit_relay > .relay/relay.sh        # emit_* funcs exist only in the bundled install.sh (Task 10)
    emit_adapters
  fi
  chmod +x .relay/relay.sh
  find .relay/adapters -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
  mkdir -p .session-log/history
}

gitignore_data() {
  touch .gitignore
  grep -qF ".session-log/" .gitignore || printf '\n%s\n.session-log/\n' "$MARK" >> .gitignore
}

append_block() { # file, source-block
  local file="$1" src="$2"
  [ -f "$src" ] || return 0
  touch "$file"
  grep -qF "$MARK" "$file" 2>/dev/null && return 0
  { printf '\n%s\n' "$MARK"; cat "$src"; printf '%s\n' "# <<< relay <<<"; } >> "$file"
}

wire_cc() {
  mkdir -p .claude/commands
  [ -d .relay/adapters/claude-code/commands ] && cp .relay/adapters/claude-code/commands/*.md .claude/commands/ 2>/dev/null || true
  append_block CLAUDE.md .relay/adapters/claude-code/CLAUDE.relay.md
  local hook=".relay/adapters/claude-code/relay-session-start.sh"
  local sj=".claude/settings.json"
  local entry
  entry="$(printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s"}]}]}}' "$hook")"
  if [ ! -f "$sj" ]; then
    printf '%s\n' "$entry" > "$sj"; return 0
  fi
  grep -qF "$hook" "$sj" && return 0    # idempotent
  if command -v jq >/dev/null 2>&1; then
    jq --arg c "$hook" '.hooks.SessionStart += [{"hooks":[{"type":"command","command":$c}]}]' "$sj" > "$sj.tmp" && mv "$sj.tmp" "$sj"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$sj" "$hook" <<'PY'
import json,sys
p,hook=sys.argv[1],sys.argv[2]
d=json.load(open(p)); d.setdefault("hooks",{}).setdefault("SessionStart",[]).append({"hooks":[{"type":"command","command":hook}]})
json.dump(d,open(p,"w"),indent=2)
PY
  else
    echo "relay: cannot auto-merge $sj — add this SessionStart hook manually:" >&2
    echo "  $entry" >&2
  fi
}

wire_codex() {
  mkdir -p .codex/skills
  [ -d .relay/adapters/codex/skills ] && cp -R .relay/adapters/codex/skills/* .codex/skills/ 2>/dev/null || true
  append_block AGENTS.md .relay/adapters/codex/AGENTS.relay.md
  local cfg=".codex/config.toml"
  touch "$cfg"
  grep -qF "relay-session-start.sh" "$cfg" 2>/dev/null || cat .relay/adapters/codex/hooks.relay.toml >> "$cfg"
}

main() {
  local did=0
  [ -d .claude ] && { copy_tool; wire_cc; did=1; }
  [ -d .codex ]  && { copy_tool; wire_codex; did=1; }
  if [ "$did" = 0 ]; then
    echo "relay: no .claude/ or .codex/ detected — nothing to wire. Re-run inside a Claude Code or Codex repo." >&2
    exit 0
  fi
  gitignore_data
  echo "relay: installed. Handoffs will accumulate in .session-log/ (gitignored)."
}
main "$@"
