#!/usr/bin/env bash
# relay.sh — deterministic session-handoff helper
set -euo pipefail

RELAY_WINDOW=10
RELAY_STALE_DAYS=3
RELAY_WORD_CAP=800
RELAY_LOCK_TIMEOUT=30
RELAY_GRADUATE_AT="${RELAY_GRADUATE_AT:-3}"
RELAY_FACTS_CAP="${RELAY_FACTS_CAP:-400}"
RELAY_LESSONS_CAP="${RELAY_LESSONS_CAP:-400}"
RELAY_FACT_STALE_DAYS="${RELAY_FACT_STALE_DAYS:-90}"
RELAY_GRADUATED_SOFT="${RELAY_GRADUATED_SOFT:-8}"

usage() {
  echo "usage: relay.sh {load|save} [--dir DIR] [--format text|codex] [--digest STR]" >&2
}

main() {
  local cmd="${1:-}"; [ $# -gt 0 ] && shift || true
  DATA="${RELAY_DIR:-$PWD/.session-log}"
  if [ "$cmd" = knowledge ]; then cmd_knowledge "$@"; return $?; fi
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

_slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' \
    | tr -s '-' | sed -e 's/^-//' -e 's/-$//' | cut -c1-48
}

_fm() { sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -n1; }

_fm_set() { # file key value  (whole-file atomic rewrite; only inside frontmatter)
  local tmp; tmp="$(mktemp)"
  awk -v k="$2" -v v="$3" 'BEGIN{d=0}
    /^---$/{d++}
    { if(d==1 && index($0,k": ")==1){ print k": "v; next } print }' "$1" > "$tmp"
  mv "$tmp" "$1"
}

_body() { awk 'BEGIN{d=0} /^---$/{d++; next} d>=2{print}' "$1"; }

_set_body() { # file body
  local tmp; tmp="$(mktemp)"
  awk 'BEGIN{d=0} {print} /^---$/{d++; if(d==2) exit}' "$1" > "$tmp"
  printf '%s\n' "$2" >> "$tmp"
  mv "$tmp" "$1"
}

_provenance() {
  local src sess
  src="history/$(date +%F).md"
  if [ -f "$DATA/latest.md" ]; then
    sess="$(sed -n 's/^session:[[:space:]]*//p' "$DATA/latest.md" | head -n1)"
    [ -n "$sess" ] && src="$src#session-$sess"
  fi
  printf '%s' "$src"
}

_days_since() {
  local d="$1" e n
  [ -n "$d" ] || { printf '999999'; return; }
  e="$(to_epoch "$d" 2>/dev/null || printf 0)"; n="$(date +%s)"
  if [ "${e:-0}" -gt 0 ]; then printf '%s' $(( (n - e) / 86400 )); else printf '999999'; fi
}

_write_lesson() { # file id seen sessions first last source body
  printf -- '---\nid: %s\nkind: lesson\nseen: %s\nsessions: %s\nfirst_seen: %s\nlast_seen: %s\nsource: %s\nstatus: active\ngraduated_to: null\n---\n%s\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" > "$1"
}

_kindex() { # derived convenience cache; never load-bearing
  local kd="$DATA/knowledge" idx tmp f id
  mkdir -p "$kd"; idx="$kd/index.md"; tmp="$(mktemp)"
  printf '# Knowledge index — derived from entry files; do not edit\n' > "$tmp"
  for f in "$kd"/facts/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"
    printf 'fact · %s · confirmed:%s · last:%s · ttl:%s · conflict:%s\n' \
      "$id" "$(_fm "$f" confirmed)" "$(_fm "$f" last_confirmed)" "$(_fm "$f" ttl)" \
      "$([ -f "$kd/facts/$id.conflict" ] && printf 1 || printf 0)" >> "$tmp"
  done
  for f in "$kd"/lessons/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"
    printf 'lesson · %s · seen:%s · sessions:%s · last:%s · status:active\n' \
      "$id" "$(_fm "$f" seen)" "$(_fm "$f" sessions)" "$(_fm "$f" last_seen)" >> "$tmp"
  done
  mv "$tmp" "$idx"
}

cmd_knowledge() {
  local kept=() ; while [ $# -gt 0 ]; do
    case "$1" in
      --dir) DATA="$2"; shift 2;;
      *) kept+=("$1"); shift;;
    esac
  done
  set -- ${kept[@]+"${kept[@]}"}
  local sub="${1:-}"; [ $# -gt 0 ] && shift || true
  case "$sub" in
    add)        k_add "$@";;
    *) echo "relay: unknown knowledge subcommand: ${sub:-(none)}" >&2; return 2;;
  esac
}

k_add() {
  local kind="" near=0 id="" ttl="none" rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --fact)   kind="fact";   shift;;
      --lesson) kind="lesson"; shift;;
      --near)   near=1;        shift;;
      --id)     id="$2";       shift 2;;
      --ttl)    ttl="$2";      shift 2;;
      *)        rest+=("$1");  shift;;
    esac
  done
  set -- ${rest[@]+"${rest[@]}"}
  local body="${1:-}"
  [ -n "$kind" ] || { echo "relay: knowledge add needs --fact or --lesson" >&2; return 2; }
  [ -n "$id" ] || { echo "relay: knowledge add needs --id <slug>" >&2; return 2; }
  id="$(_slugify "$id")"
  _lock || return 1
  mkdir -p "$DATA/knowledge/facts" "$DATA/knowledge/lessons"
  if [ "$kind" = lesson ]; then _k_add_lesson "$id" "$body"; fi
  _kindex
  _unlock
}

_k_add_lesson() {
  local id="$1" body="$2" f="$DATA/knowledge/lessons/$1.md" today
  today="$(date +%F)"
  if [ -f "$f" ]; then
    local seen sess last
    seen="$(_fm "$f" seen)"; sess="$(_fm "$f" sessions)"; last="$(_fm "$f" last_seen)"
    seen=$(( ${seen:-1} + 1 ))
    [ "$last" != "$today" ] && sess=$(( ${sess:-1} + 1 ))
    _fm_set "$f" seen "$seen"; _fm_set "$f" sessions "$sess"; _fm_set "$f" last_seen "$today"
    _set_body "$f" "$body"
    echo "reinforced lesson: $id (seen:$seen sessions:$sess)"
    if [ "$sess" -ge "$RELAY_GRADUATE_AT" ]; then
      echo "  → graduation-ready (sessions:$sess ≥ $RELAY_GRADUATE_AT): propose 'relay knowledge graduate $id'"
    fi
  else
    _write_lesson "$f" "$id" 1 1 "$today" "$today" "$(_provenance)" "$body"
    echo "added lesson: $id (seen:1 sessions:1)"
  fi
  return 0   # never let a false test/[-ge] make this function exit non-zero under set -e
}

main "$@"
