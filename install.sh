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

wire_opencode() {
  mkdir -p .opencode/commands
  [ -d .relay/adapters/opencode/commands ] && cp .relay/adapters/opencode/commands/*.md .opencode/commands/ 2>/dev/null || true
  append_block AGENTS.md .relay/adapters/opencode/AGENTS.relay.md
  # opencode has no SessionStart-style "inject into context" hook; the native
  # equivalent is the `instructions` array in opencode.json, loaded as system
  # context at every session start. We point it at a snapshot file that
  # /session-save and /relay-learn refresh after every write.
  local cfg="" entry=".session-log/relay-instructions.md"
  for f in opencode.jsonc opencode.json; do [ -f "$f" ] && { cfg="$f"; break; }; done
  [ -n "$cfg" ] || cfg="opencode.json"
  touch "$cfg"
  grep -qF "$entry" "$cfg" 2>/dev/null && return 0    # idempotent
  if command -v jq >/dev/null 2>&1; then
    jq --arg p "$entry" '.instructions = ((.instructions // []) + [$p])' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$cfg" "$entry" <<'PY'
import json, re, sys
p, entry = sys.argv[1], sys.argv[2]
with open(p) as f: raw = f.read()
# strip JSONC comments (json is strict); preserve everything else
stripped = re.sub(r'//.*$', '', raw, flags=re.MULTILINE)
stripped = re.sub(r'/\*.*?\*/', '', stripped, flags=re.DOTALL)
d = json.loads(stripped) if stripped.strip() else {}
instr = d.setdefault("instructions", [])
if entry not in instr: instr.append(entry)
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
  else
    echo "relay: cannot auto-merge $cfg — add this path to the 'instructions' array manually:" >&2
    echo "  $entry" >&2
  fi
  # seed an empty snapshot so the instructions path doesn't 404 before the first save
  mkdir -p .session-log
  [ -f "$entry" ] || printf '# Relay handoff will appear here after the first /session-save\n' > "$entry"
}

main() {
  local did=0
  [ -d .claude ]   && { copy_tool; wire_cc; did=1; }
  [ -d .codex ]    && { copy_tool; wire_codex; did=1; }
  { [ -d .opencode ] || [ -f opencode.json ] || [ -f opencode.jsonc ]; } && { copy_tool; wire_opencode; did=1; }
  if [ "$did" = 0 ]; then
    echo "relay: no .claude/, .codex/, or .opencode/ detected — nothing to wire. Re-run inside a Claude Code, Codex, or opencode repo." >&2
    exit 0
  fi
  gitignore_data
  echo "relay: installed. Handoffs will accumulate in .session-log/ (gitignored)."
}
main "$@"
