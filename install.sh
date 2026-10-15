#!/usr/bin/env bash
# install.sh — lay Relay into the current repo. (Bundled release embeds sources; --from uses a source tree.)
# usage: install.sh [--clis claude,codex,opencode,cursor,grok] [--detect] [--from SRC]
#   no flags + a terminal → asks which CLIs to wire (detected ones pre-checked)
#   --clis              → wire exactly these, no prompt
#   --detect / no tty   → wire whatever CLIs are already present in the repo
set -euo pipefail
MARK="# >>> relay >>>"
FROM="" CLIS="" DETECT=0
ALL_CLIS="claude codex opencode cursor grok"

usage() {
  echo "usage: install.sh [--clis claude,codex,opencode,cursor,grok] [--detect] [--from SRC]" >&2
}

copy_tool() {
  mkdir -p .relay
  if [ -n "$FROM" ]; then
    cp "$FROM/relay.sh" .relay/relay.sh
    rm -rf .relay/adapters                 # tool-owned; replace so re-runs don't nest adapters/adapters
    cp -R "$FROM/adapters" .relay/adapters
    mkdir -p .relay/tests
    cp "$FROM/tests/smoke-compact.sh" .relay/tests/smoke-compact.sh
  else
    emit_relay > .relay/relay.sh        # emit_* funcs exist only in the bundled install.sh (Task 10)
    rm -rf .relay/adapters
    emit_adapters
    mkdir -p .relay/tests
    emit_smoke_compact > .relay/tests/smoke-compact.sh
  fi
  chmod +x .relay/relay.sh .relay/tests/smoke-compact.sh
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
  # idempotent per adapter: each source's first line is its own header comment.
  # Already present → replace that block in place so re-installs pick up new wording.
  if grep -qF "$(head -n 1 "$src")" "$file" 2>/dev/null; then
    awk -v mark="$MARK" -v endm="# <<< relay <<<" -v hdr="$(head -n 1 "$src")" -v src="$src" '
      $0 == mark { inblk = 1; buf = $0 "\n"; next }
      inblk {
        buf = buf $0 "\n"
        if ($0 == endm) {
          inblk = 0
          if (index(buf, hdr)) {
            print mark
            while ((getline line < src) > 0) print line
            close(src)
            print endm
          } else printf "%s", buf
        }
        next
      }
      { print }
      END { if (inblk) printf "%s", buf }
    ' "$file" > "$file.relaytmp" && mv "$file.relaytmp" "$file"
    return 0
  fi
  { printf '\n%s\n' "$MARK"; cat "$src"; printf '%s\n' "# <<< relay <<<"; } >> "$file"
}

copy_skills() { # dest skills dir — the shared session-save / relay-learn / relay-compact skills
  local dest="$1" d
  mkdir -p "$dest"
  for d in .relay/adapters/skills/*/; do
    d="${d%/}"; rm -rf "$dest/${d##*/}"; cp -R "$d" "$dest/${d##*/}"
  done
}

drop_legacy_commands() { # dir prefix — remove Relay-owned command files from older installs
  local f
  for f in "$1"/session-save.md "$1"/relay-learn.md "$1"/relay-compact.md; do
    [ -f "$f" ] && grep -qF "<!-- adapters/$2/commands/" "$f" && rm -f "$f"
  done
  return 0
}

wire_cc() {
  copy_skills .claude/skills
  drop_legacy_commands .claude/commands claude-code
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
  for f in opencode.jsonc opencode.json .opencode/opencode.jsonc .opencode/opencode.json; do [ -f "$f" ] && { cfg="$f"; break; }; done
  [ -n "$cfg" ] || cfg="opencode.json"
  [ -s "$cfg" ] || printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' > "$cfg"
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

wire_cursor() {
  copy_skills .cursor/skills
  append_block AGENTS.md .relay/adapters/cursor/AGENTS.relay.md
}

wire_grok() {
  copy_skills .grok/skills
  drop_legacy_commands .grok/commands grok
  mkdir -p .grok/hooks
  append_block AGENTS.md .relay/adapters/grok/AGENTS.relay.md
  # Grok reads project hooks from .grok/hooks/*.json (after /hooks-trust)
  [ -f .grok/hooks/relay.json ] || cp .relay/adapters/grok/hooks.relay.json .grok/hooks/relay.json
}

cli_label() {
  case "$1" in
    claude) echo "Claude Code";; codex) echo "Codex";;
    opencode) echo "OpenCode";; cursor) echo "Cursor";; grok) echo "Grok Build";;
  esac
}

detect_clis() {
  local found=""
  [ -d .claude ] && found="$found claude"
  [ -d .codex ]  && found="$found codex"
  { [ -d .opencode ] || [ -f opencode.json ] || [ -f opencode.jsonc ]; } && found="$found opencode"
  [ -d .cursor ] && found="$found cursor"
  [ -d .grok ]   && found="$found grok"
  echo "${found# }"
}

normalize_clis() { # comma/space list with aliases → canonical space list, in ALL_CLIS order
  local raw out="" c
  raw=" $(printf '%s' "$1" | tr ',[:upper:]' ' [:lower:]') "
  raw="$(printf '%s' "$raw" | sed -e 's/ claude-code / claude /g; s/ cc / claude /g; s/ open-code / opencode /g; s/ grok-build / grok /g; s/ cursor-agent / cursor /g')"
  for c in $raw; do
    case " $ALL_CLIS all " in *" $c "*) ;; *) echo "relay: unknown CLI '$c' (choose from: $ALL_CLIS)" >&2; return 2;; esac
  done
  for c in $ALL_CLIS; do
    case "$raw" in *" $c "*|*" all "*) out="$out $c";; esac
  done
  echo "${out# }"
}

prompt_clis() { # $1 = tty to read from; $2 = pre-selected list
  local tty="$1" sel=" $2 " c i m ans n
  exec 3<"$tty"                            # open once so each read advances
  while :; do
    {
      echo ""
      echo "Which CLIs should Relay be wired for in this repo?"
      i=1
      for c in $ALL_CLIS; do
        case "$sel" in *" $c "*) m="x";; *) m=" ";; esac
        printf '  %d) [%s] %s\n' "$i" "$m" "$(cli_label "$c")"
        i=$((i + 1))
      done
      printf 'Toggle by number (e.g. "1 4"), "a" = all, "n" = none, Enter = done: '
    } >&2
    IFS= read -r ans <&3 || ans=""
    [ -z "$ans" ] && break
    for n in $(printf '%s' "$ans" | tr ',' ' '); do
      case "$n" in
        a|A) sel=" $ALL_CLIS ";;
        n|N) sel=" ";;
        [1-5]) c="$(echo $ALL_CLIS | cut -d' ' -f"$n")"
               case "$sel" in *" $c "*) sel="$(printf '%s' "$sel" | sed "s/ $c / /")";; *) sel="$sel$c ";; esac;;
        *) echo "relay: ignoring '$n'" >&2;;
      esac
    done
  done
  exec 3<&-
  normalize_clis "$sel"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)   [ $# -ge 2 ] || { usage; exit 2; }; FROM="$2"; shift 2;;
      --clis)   [ $# -ge 2 ] || { usage; exit 2; }; CLIS="$2"; shift 2;;
      --clis=*) CLIS="${1#--clis=}"; shift;;
      --detect) DETECT=1; shift;;
      -h|--help) usage; exit 0;;
      *) echo "relay: unknown option '$1'" >&2; usage; exit 2;;
    esac
  done

  # run from a source checkout (no embedded emit_* funcs) → use the checkout itself
  if [ -z "$FROM" ] && ! command -v emit_relay >/dev/null 2>&1; then
    FROM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  local selected detected
  detected="$(detect_clis)"
  if [ -n "$CLIS" ]; then
    selected="$(normalize_clis "$CLIS")" || exit 2
  elif [ "$DETECT" = 1 ]; then
    selected="$detected"
  elif [ -n "${RELAY_TTY:-}" ]; then        # test hook: answers come from a file
    selected="$(prompt_clis "$RELAY_TTY" "$detected")"
  elif [ -t 0 ]; then
    selected="$(prompt_clis /dev/stdin "$detected")"
  elif { : </dev/tty; } 2>/dev/null; then    # piped install (curl | bash) still has a terminal
    selected="$(prompt_clis /dev/tty "$detected")"
  else
    selected="$detected"
  fi

  if [ -z "$selected" ]; then
    echo "relay: no CLIs selected or detected — nothing to wire. Re-run with --clis claude,codex,opencode,cursor,grok." >&2
    exit 0
  fi

  copy_tool
  local c
  for c in $selected; do
    case "$c" in
      claude) wire_cc;; codex) wire_codex;; opencode) wire_opencode;; cursor) wire_cursor;; grok) wire_grok;;
    esac
  done
  gitignore_data
  local labels=""
  for c in $selected; do labels="$labels, $(cli_label "$c")"; done
  echo "relay: installed for ${labels#, }. Handoffs will accumulate in .session-log/ (gitignored)."
  case " $selected " in *" grok "*) echo "relay: in Grok, run /hooks-trust once so the SessionStart hook can load the handoff.";; esac
}
main "$@"
