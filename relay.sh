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

cmd_load() { return 0; }   # filled in Task 6

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
