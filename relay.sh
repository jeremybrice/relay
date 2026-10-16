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
RELAY_LESSON_COLD_DAYS="${RELAY_LESSON_COLD_DAYS:-30}"
RELAY_FACTS_MAX="${RELAY_FACTS_MAX:-40}"
RELAY_LESSONS_MAX="${RELAY_LESSONS_MAX:-30}"
RELAY_FORMAT=2   # on-disk layout of .session-log/ (2 = table indexes). Bump on any change an older relay.sh would mangle.

usage() {
  echo "usage: relay.sh {load|save} [--dir DIR] [--format text|codex|grok] [--digest STR]" >&2
}

main() {
  local cmd="${1:-}"; [ $# -gt 0 ] && shift || true
  DATA="${RELAY_DIR:-$PWD/.session-log}"
  if [ "$cmd" = knowledge ]; then cmd_knowledge "$@"; return $?; fi
  local format="text" digest=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)    [ $# -ge 2 ] || { echo "relay: --dir needs a value" >&2; return 2; };    DATA="$2";   shift 2;;
      --format) [ $# -ge 2 ] || { echo "relay: --format needs a value" >&2; return 2; }; format="$2"; shift 2;;
      --digest) [ $# -ge 2 ] || { echo "relay: --digest needs a value" >&2; return 2; }; digest="$2"; shift 2;;
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

_md_table() { # "Col1<TAB>Col2…"; TSV rows on stdin -> column-padded Markdown table
  awk -F'\t' -v hdr="$1" '
    function pad(s, w) { while (length(s) < w) s = s " "; return s }
    function rule(w,   o) { o = ""; while (w-- > 0) o = o "-"; return o }
    function row(a,   i, o) { o = "|"; for (i = 1; i <= nc; i++) o = o " " pad(a[i], w[i]) " |"; return o }
    BEGIN { nc = split(hdr, h, "\t"); for (i = 1; i <= nc; i++) w[i] = length(h[i]) }
    { n++; for (i = 1; i <= nc; i++) { c[n, i] = $i; if (length($i) > w[i]) w[i] = length($i) } }
    END {
      print row(h)
      o = "|"; for (i = 1; i <= nc; i++) o = o rule(w[i] + 2) "|"; print o
      for (r = 1; r <= n; r++) { for (i = 1; i <= nc; i++) a[i] = c[r, i]; print row(a) }
    }'
}

_index_rows() { # index.md (table or legacy "- date — digest → history/…" lines) -> date<TAB>digest
  awk '
    /^\| [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] \|/ {
      split($0, f, "|"); d = f[2]; s = f[3]
      gsub(/^ +| +$/, "", d); gsub(/^ +| +$/, "", s); print d "\t" s; next
    }
    /^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / {
      d = substr($0, 3, 10); s = substr($0, 14)
      sub(/^— /, "", s); sub(/ → history\/[^ ]*\.md$/, "", s); gsub(/\|/, "/", s); print d "\t" s
    }' "$1"
}

_index_update() {
  local date="$1" digest="$2" idx="$DATA/index.md" tmp
  digest="$(printf '%s' "$digest" | tr '\n\t|' '  /')"   # a pipe or line break would split the table row
  tmp="$(mktemp)"
  {
    printf '# Session index (last %s days)\n\n' "$RELAY_WINDOW"
    {
      printf '%s\t%s\n' "$date" "$digest"
      if [ -f "$idx" ]; then _index_rows "$idx"; fi
    } | awk -F'\t' -v win="$RELAY_WINDOW" \
          '!seen[$1]++ && ++n <= win { print $1 "\t" $2 "\t[" $1 "](history/" $1 ".md)" }' \
      | _md_table $'Date\tSummary\tHistory'
  } > "$tmp"
  mv "$tmp" "$idx"
}

_unlock() { [ -n "${DATA:-}" ] && rm -rf "$DATA/.lock" 2>/dev/null || true; }

_format_have() { local v; v="$(cat "$DATA/.relay-format" 2>/dev/null || true)"; case "$v" in ''|*[!0-9]*) v=0;; esac; printf '%s' "$v"; }

_format_ok() { # refuse a store written by a newer Relay; stamp an older or unstamped one
  local have; have="$(_format_have)"
  if [ "$have" -gt "$RELAY_FORMAT" ]; then
    echo "relay: $DATA uses format $have but this relay.sh writes format $RELAY_FORMAT; update this repo's Relay with: install.sh --detect" >&2
    return 1
  fi
  [ "$have" = "$RELAY_FORMAT" ] || printf '%s\n' "$RELAY_FORMAT" > "$DATA/.relay-format"
}

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
  _format_ok || { _unlock; return 1; }
}

_prune() { # keep the newest RELAY_WINDOW history files; glob order is ascending by YYYY-MM-DD name
  local files i
  files=("$DATA/history"/*.md)
  [ -e "${files[0]}" ] || return 0
  for (( i = 0; i < ${#files[@]} - RELAY_WINDOW; i++ )); do rm -f "${files[$i]}"; done
  return 0
}

_json_escape() {
  awk 'BEGIN{ORS=""}
       { gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t");
         if (NR>1) printf "\\n"; printf "%s", $0 }'
}

_uniq_dest() { # full path ending in .md -> a non-colliding path on stdout
  local p="$1" stem n
  [ -e "$p" ] || { printf '%s' "$p"; return; }   # free → use as-is (first tombstone keeps base name)
  stem="${p%.md}"; n=2
  while [ -e "$stem.$n.md" ]; do n=$(( n + 1 )); done
  printf '%s' "$stem.$n.md"
}

_ttl_limit() { # raw on-disk ttl -> safe numeric day limit; anything not a small non-negative int -> default
  local t="${1:-}"; t="${t//[[:space:]]/}"   # tolerate stray whitespace from hand-edits (e.g. "ttl: 30 ")
  case "$t" in
    ''|none|*[!0-9]*) printf '%s' "$RELAY_FACT_STALE_DAYS"; return ;;
  esac
  [ "${#t}" -le 7 ] || { printf '%s' "$RELAY_FACT_STALE_DAYS"; return; }   # >7 digits overflows [ -gt ]
  printf '%s' "$(( 10#$t ))"   # force base-10 (no "08" octal error) and normalize leading zeros
}

_kblock() { # word cap; ranked "...<TAB>id<TAB>line" rows on stdin -> each line in full if it still fits the cap (rank order), the rest on one id-only line
  awk -F'\t' -v cap="$1" '
    { id = $(NF - 1); line = $NF; n = split(line, w, " ")
      if (words + n <= cap || shown == 0) { words += n; shown++; print line; next }
      more++; rest = rest (more > 1 ? ", " : "") id }
    END { if (more) printf "More (%d, by id; open with: relay knowledge why <id>): %s\n", more, rest }'
}

_load_knowledge() {
  local kd="$DATA/knowledge" f id body conf last ttl age seen
  [ -d "$kd/facts" ] || [ -d "$kd/lessons" ] || return 0
  local out="" tmp sorted total shown block exp=0 conflicts=0

  # ---- FACTS: rank by confirmed, then recency; every entry named by id ----
  tmp="$(mktemp)"
  for f in "$kd"/facts/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"; conf="$(_fm "$f" confirmed)"; last="$(_fm "$f" last_confirmed)"; ttl="$(_fm "$f" ttl)"
    body="$(_body "$f" | tr '\n\t' '  ' | sed 's/ *$//')"
    age="$(_days_since "$last")"
    local lim; lim="$(_ttl_limit "$ttl")"
    [ "$age" -gt "$lim" ] && exp=$(( exp + 1 ))
    [ -f "$kd/facts/$id.conflict" ] && conflicts=$(( conflicts + 1 ))
    printf '%03d\t%09d\t%s\t- `%s`: %s (confirmed:%s)\n' \
      "${conf:-1}" "$(( 999999 - age ))" "$id" "$id" "$body" "${conf:-1}" >> "$tmp"
  done
  if [ -s "$tmp" ]; then
    total="$(grep -c . "$tmp" || true)"
    block="$(sort -t$'\t' -k1,1nr -k2,2nr "$tmp" | _kblock "$RELAY_FACTS_CAP")"
    shown="$(printf '%s\n' "$block" | grep -c '^- ' || true)"
    out="${out}## What this repo knows — facts"$'\n'
    [ "$shown" -lt "$total" ] && out="${out}⚠ $shown of $total facts shown in full; the rest are listed by id at the end of this section"$'\n'
    out="${out}${block}"$'\n'
    [ "$exp" -gt 0 ] && out="${out}($exp fact(s) past freshness window — run: relay knowledge prune)"$'\n'
    [ "$conflicts" -gt 0 ] && out="${out}(⚠ $conflicts fact conflict(s) pending — run: relay knowledge resolve <id>)"$'\n'
    [ "$total" -gt "$RELAY_FACTS_MAX" ] && out="${out}(⚠ $total facts over cap $RELAY_FACTS_MAX — run: relay knowledge compact)"$'\n'
  fi
  rm -f "$tmp"

  # ---- LESSONS (active): rank by seen, then recency; every entry named by id ----
  tmp="$(mktemp)"
  for f in "$kd"/lessons/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"; seen="$(_fm "$f" seen)"; seen="${seen:-1}"
    body="$(_body "$f" | tr '\n\t' '  ' | sed 's/ *$//')"
    age="$(_days_since "$(_fm "$f" last_seen)")"
    printf '%05d\t%09d\t%s\t- `%s`: %s (seen:%s, sessions:%s)\n' \
      "$seen" "$(( 999999 - age ))" "$id" "$id" "$body" "$seen" "$(_fm "$f" sessions)" >> "$tmp"
  done
  if [ -s "$tmp" ]; then
    total="$(grep -c . "$tmp" || true)"
    block="$(sort -t$'\t' -k1,1nr -k2,2nr "$tmp" | _kblock "$RELAY_LESSONS_CAP")"
    shown="$(printf '%s\n' "$block" | grep -c '^- ' || true)"
    out="${out}## What this repo knows — lessons"$'\n'
    out="${out}(If one of these applied again this session, re-assert it by id when saving: knowledge add --lesson --id <id> ...)"$'\n'
    [ "$shown" -lt "$total" ] && out="${out}⚠ $shown of $total lessons shown in full; the rest are listed by id at the end of this section"$'\n'
    out="${out}${block}"$'\n'
    [ "$total" -gt "$RELAY_LESSONS_MAX" ] && out="${out}(⚠ $total lessons over cap $RELAY_LESSONS_MAX — run: relay knowledge compact)"$'\n'
  fi
  rm -f "$tmp"

  # ---- oversized graduated-block nudge (spec §7.1 — the uncapped instruction surface) ----
  local instr gcount
  instr="$(_instruction_file)"
  if [ -f "$instr" ]; then
    gcount="$(grep -cF '<!-- relay:learned:' "$instr" 2>/dev/null)" || gcount=0
    if [ "${gcount:-0}" -ge "${RELAY_GRADUATED_SOFT:-8}" ]; then
      out="${out}(⚠ $gcount graduated rules in $(basename "$instr") — review/consolidate via: relay knowledge list / ungraduate)"$'\n'
    fi
  fi

  [ -n "$out" ] && printf '%s' "$out"
  return 0
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
  if [ "$(_format_have)" -gt "$RELAY_FORMAT" ]; then
    out="⚠ This .session-log was written by a newer Relay (format $(_format_have)); update .relay/ with install.sh --detect before saving."$'\n\n'"$out"
  fi
  n="$(wc -w < "$latest" | tr -d ' ')"
  if [ "${n:-0}" -gt "$RELAY_WORD_CAP" ]; then
    out="$out$(awk -v cap="$RELAY_WORD_CAP" 'BEGIN{c=0}{c+=NF;print} c>=cap{print "\n…[truncated — open .session-log/latest.md for the full handoff]"; exit}' "$latest")"
  else
    out="$out$(cat "$latest")"
  fi
  local kblock; kblock="$(_load_knowledge)"
  [ -n "$kblock" ] && out="$out"$'\n\n'"$kblock"
  [ -f "$idx" ] && out="$out"$'\n\n'"$(cat "$idx")"
  out="$out"$'\n\nThe handoff and index above are summaries. If the task touches work from an earlier day in the index, open .session-log/history/<date>.md before starting.'
  if [ "$format" = "codex" ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
      "$(printf '%s' "$out" | _json_escape)"
  elif [ "$format" = "grok" ]; then
    printf '{"systemMessage":"%s"}\n' "$(printf '%s' "$out" | _json_escape)"
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
    | tr -s '-' | sed -e 's/^-//' -e 's/-$//'
}

_squash() { printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }

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

_provenance() { # today's history file, anchored to today's last saved session when there is one
  local today src sess
  today="$(date +%F)"; src="history/$today.md"
  if [ -f "$DATA/latest.md" ] && [ "$(_fm "$DATA/latest.md" date)" = "$today" ]; then
    sess="$(_fm "$DATA/latest.md" session)"
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
  local kd="$DATA/knowledge" idx tmp f id facts="" lessons=""
  mkdir -p "$kd"; idx="$kd/index.md"; tmp="$(mktemp)"
  for f in "$kd"/facts/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"
    facts="$facts$(printf '%s\t%s\t%s\t%s\t%s' \
      "$id" "$(_fm "$f" confirmed)" "$(_fm "$f" last_confirmed)" "$(_fm "$f" ttl)" \
      "$([ -f "$kd/facts/$id.conflict" ] && printf yes || printf no)")"$'\n'
  done
  for f in "$kd"/lessons/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"
    lessons="$lessons$(printf '%s\t%s\t%s\t%s\tactive' \
      "$id" "$(_fm "$f" seen)" "$(_fm "$f" sessions)" "$(_fm "$f" last_seen)")"$'\n'
  done
  {
    printf '# Knowledge index (derived from entry files; do not edit)\n'
    if [ -n "$facts" ]; then
      printf '\n## Facts\n\n'
      printf '%s' "$facts" | _md_table $'ID\tConfirmed\tLast\tTTL\tConflict'
    fi
    if [ -n "$lessons" ]; then
      printf '\n## Lessons\n\n'
      printf '%s' "$lessons" | _md_table $'ID\tSeen\tSessions\tLast\tStatus'
    fi
  } > "$tmp"
  mv "$tmp" "$idx"
}

_write_fact() { # file id confirmed first last ttl source body
  printf -- '---\nid: %s\nkind: fact\nconfirmed: %s\nfirst_seen: %s\nlast_confirmed: %s\nttl: %s\nsource: %s\nstatus: active\n---\n%s\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" > "$1"
}

_dice() { # bodyA bodyB -> integer 0..100 (Dice coefficient over unique lowercase tokens)
  # Bodies MUST be passed via files, not `awk -v`: BSD/POSIX awk rejects a newline
  # inside a -v value, which would hard-fail similarity on any multi-line body.
  local fa fb r
  fa="$(mktemp)"; fb="$(mktemp)"
  printf '%s' "$1" > "$fa"; printf '%s' "$2" > "$fb"
  r="$(awk '
    FNR==NR { n=split(tolower($0),w,/[^a-z0-9]+/); for(i=1;i<=n;i++) if(w[i]!="") sa[w[i]]=1; next }
            { n=split(tolower($0),w,/[^a-z0-9]+/); for(i=1;i<=n;i++) if(w[i]!="") sb[w[i]]=1 }
    END{ ca=0; for(k in sa) ca++; cb=0; for(k in sb) cb++;
         inter=0; for(k in sa) if(k in sb) inter++;
         if(ca+cb==0){ print 0; exit }
         printf "%d", (inter*200)/(ca+cb) }' "$fa" "$fb")"
  rm -f "$fa" "$fb"
  printf '%s' "$r"
}

_similar() { [ "$(_dice "$1" "$2")" -ge 50 ]; }

_k_add_fact() {
  local id="$1" body="$2" ttl="${3:-none}" f="$DATA/knowledge/facts/$1.md" today
  today="$(date +%F)"
  if [ -f "$f" ]; then
    if _similar "$(_body "$f")" "$body"; then
      local c; c="$(_fm "$f" confirmed)"; c=$(( ${c:-1} + 1 ))
      if [ "$(_squash "$(_body "$f")")" != "$(_squash "$body")" ]; then
        # a restatement is the agent's current understanding: newest wording wins, old kept for recovery
        local prev; mkdir -p "$DATA/knowledge/facts/superseded"
        prev="$(_uniq_dest "$DATA/knowledge/facts/superseded/$id.prev.md")"
        cp "$f" "$prev"
        _set_body "$f" "$body"
        echo "updated wording: $id (previous kept in facts/superseded/$(basename "$prev"))"
      fi
      _fm_set "$f" confirmed "$c"; _fm_set "$f" last_confirmed "$today"
      [ "$ttl" != none ] && _fm_set "$f" ttl "$ttl"    # refresh freshness window if the agent re-set it
      echo "confirmed: $id (confirmed:$c)"
    else
      printf '%s\n' "$body" > "$DATA/knowledge/facts/$id.conflict"
      echo "⚠ conflict raised for fact: $id — run: relay knowledge resolve $id"
    fi
  else
    _write_fact "$f" "$id" 1 "$today" "$today" "$ttl" "$(_provenance)" "$body"
    echo "added fact: $id"
  fi
  return 0
}

_k_near() { # kind body
  local dir="$DATA/knowledge/${1}s" body="$2" f id sc w words hits=""
  [ -d "$dir" ] || { echo "(no existing ${1}s yet — safe to create a new id)"; return 0; }
  words="$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '\n' \
            | awk 'length>=4' | sort -u)"
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"; sc=0
    for w in $words; do grep -qiF -- "$w" "$f" && sc=$(( sc + 1 )); done
    [ "$sc" -gt 0 ] && hits="$hits$sc $id
"
  done
  if [ -n "$hits" ]; then
    echo "Closest existing ${1} ids (reuse one as --id if it matches):"
    printf '%s' "$hits" | sort -rn | head -n3 | awk '{printf "  - %s (overlap %s)\n",$2,$1}'
  else
    echo "(no near matches — safe to create a new id)"
  fi
}

k_resolve() {
  local keep="existing" id="" rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep) { [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; } || { echo "relay: --keep needs a value (new|existing)" >&2; return 1; }; keep="$2"; shift 2;;
      *) rest+=("$1"); shift;;
    esac
  done
  set -- ${rest[@]+"${rest[@]}"}
  id="$(_slugify "${1:-}")"
  local f="$DATA/knowledge/facts/$id.md" cf="$DATA/knowledge/facts/$id.conflict"
  case "$keep" in new|existing) ;; *) echo "relay: --keep must be 'new' or 'existing': $keep" >&2; return 1 ;; esac
  [ -f "$cf" ] || { echo "relay: no pending conflict for: $id" >&2; return 1; }
  if [ "$keep" = existing ] && [ ! -f "$f" ]; then
    echo "relay: no existing fact for '$id' to keep — only a pending conflict exists; use --keep new to promote it" >&2
    return 1
  fi
  _lock || return 1
  mkdir -p "$DATA/knowledge/facts/superseded"
  if [ "$keep" = new ]; then
    if [ -f "$f" ]; then
      cp "$f" "$(_uniq_dest "$DATA/knowledge/facts/superseded/$id.original.md")"
      _set_body "$f" "$(cat "$cf")"
      _fm_set "$f" last_confirmed "$(date +%F)"
    else
      # orphan conflict (fact .md gone): promote the conflict body to a fresh fact
      _write_fact "$f" "$id" 1 "$(date +%F)" "$(date +%F)" none "$(_provenance)" "$(cat "$cf")"
    fi
  else
    local dest; dest="$(_uniq_dest "$DATA/knowledge/facts/superseded/$id.losing.md")"
    printf -- '---\nid: %s\nkind: fact\nstatus: superseded\nsource: %s\n---\n%s\n' \
      "$id" "$(_provenance)" "$(cat "$cf")" > "$dest"
  fi
  rm -f "$cf"
  _kindex
  _unlock
  echo "resolved: $id (kept $keep)"
}

_instruction_file() {
  if [ -n "${RELAY_INSTRUCTION_FILE:-}" ]; then printf '%s' "$RELAY_INSTRUCTION_FILE"; return; fi
  local f
  # a file already holding graduated blocks stays the target (older installs used CLAUDE.md)
  for f in AGENTS.md CLAUDE.md; do
    grep -qF '<!-- relay:learned:' "$PWD/$f" 2>/dev/null && { printf '%s' "$PWD/$f"; return; }
  done
  # AGENTS.md is read by every supported CLI, Claude Code included
  if [ -f "$PWD/AGENTS.md" ] || [ ! -f "$PWD/CLAUDE.md" ]; then printf '%s' "$PWD/AGENTS.md"
  else printf '%s' "$PWD/CLAUDE.md"; fi
}

_block_upsert() { # file id body  (idempotent; replaces any existing id-block)
  local file="$1" id="$2" body="$3" tmp bodyf
  touch "$file"
  grep -qF "<!-- relay:learned -->" "$file" || \
    printf '\n<!-- relay:learned -->\n<!-- /relay:learned -->\n' >> "$file"
  # Body MUST be passed via a file, not `awk -v`: BSD/POSIX awk rejects a newline
  # inside a -v value, which would hard-fail graduation of any multi-line lesson.
  bodyf="$(mktemp)"; printf '%s\n' "$body" > "$bodyf"
  tmp="$(mktemp)"
  awk -v id="$id" -v bodyf="$bodyf" '
    BEGIN{ s="<!-- relay:learned:"id" -->"; e="<!-- /relay:learned:"id" -->";
           rend="<!-- /relay:learned -->"; skip=0; done=0 }
    {
      if($0==s){ skip=1; next }
      if(skip==1){ if($0==e) skip=0; next }
      if($0==rend && done==0){
        print s; while((getline ln < bodyf) > 0) print ln; close(bodyf); print e; done=1; print; next
      }
      print
    }
    END{ if(done==0){ print s; while((getline ln < bodyf) > 0) print ln; close(bodyf); print e; print rend } }' "$file" > "$tmp"
  mv "$tmp" "$file"
  rm -f "$bodyf"
}

k_graduate() {
  local id; id="$(_slugify "${1:-}")"
  local f="$DATA/knowledge/lessons/$id.md"
  if [ ! -f "$f" ]; then
    [ -f "$DATA/knowledge/lessons/graduated/$id.md" ] && { echo "already graduated: $id"; return 0; }
    echo "relay: no active lesson: $id" >&2; return 1
  fi
  _lock || return 1
  local target; target="$(_instruction_file)"
  _block_upsert "$target" "$id" "$(_body "$f")"
  _fm_set "$f" status graduated
  _fm_set "$f" graduated_to "$target"
  mkdir -p "$DATA/knowledge/lessons/graduated"
  mv "$f" "$DATA/knowledge/lessons/graduated/$id.md"
  _kindex
  _unlock
  # the one local→committed leak, named at the helper layer (spec §7.2), not just in adapter prose
  echo "note: wrote to $target (a normally-committed file) — local-only learning may now travel; committing it is your choice." >&2
  echo "graduated: $id → $target"
}

cmd_knowledge() {
  local kept=() ; while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || { echo "relay: --dir needs a value" >&2; return 2; }; DATA="$2"; shift 2;;
      *) kept+=("$1"); shift;;
    esac
  done
  set -- ${kept[@]+"${kept[@]}"}
  local sub="${1:-}"; [ $# -gt 0 ] && shift || true
  case "$sub" in
    add)        k_add "$@";;
    resolve)    k_resolve "$@";;
    list)       k_list "$@";;
    graduate)   k_graduate "$@";;
    ungraduate) k_ungraduate "$@";;
    supersede)  k_supersede "$@";;
    prune)      k_prune "$@";;
    compact)    k_compact "$@";;
    restore)    k_restore "$@";;
    why)        k_why "$@";;
    export)     k_export "$@";;
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
      --id)     { [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; } || { echo "relay: --id needs a value" >&2; return 2; };  id="$2";  shift 2;;
      --ttl)    { [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; } || { echo "relay: --ttl needs a value" >&2; return 2; }; ttl="$2"; shift 2;;
      -)        rest+=("$(cat)"); shift;;          # body on stdin: no shell quoting to get wrong
      --*)      case "$1" in
                  *[[:space:]]*) rest+=("$1"); shift;;   # a body that starts with --, not a flag
                  *) echo "relay: unknown option for knowledge add: $1 (the body is one quoted argument, or - for stdin)" >&2; return 2;;
                esac;;
      *)        rest+=("$1");  shift;;
    esac
  done
  set -- ${rest[@]+"${rest[@]}"}
  [ $# -le 1 ] || { echo "relay: knowledge add takes one body argument; quote the whole body or pass - and use stdin (got $#)" >&2; return 2; }
  local body="${1:-}"
  [ -n "$kind" ] || { echo "relay: knowledge add needs --fact or --lesson" >&2; return 2; }
  [ -n "${body//[[:space:]]/}" ] || { echo "relay: knowledge add needs a non-empty body" >&2; return 2; }
  if [ "$near" = 1 ]; then _k_near "$kind" "$body"; return 0; fi
  [ -n "$id" ] || { echo "relay: knowledge add needs --id <slug>" >&2; return 2; }
  id="$(_slugify "$id")"
  [ -n "$id" ] || { echo "relay: --id slugifies to empty (need [a-z0-9] characters)" >&2; return 2; }
  [ "${#id}" -le 48 ] || { echo "relay: --id too long (${#id} chars after slugify; max 48): $id" >&2; return 2; }
  if [ "$ttl" != none ]; then
    case "$ttl" in
      ''|*[!0-9]*) echo "relay: --ttl must be 'none' or a non-negative integer (days): $ttl" >&2; return 2 ;;
    esac
    [ "${#ttl}" -le 7 ] || { echo "relay: --ttl too large (max 7 digits): $ttl" >&2; return 2; }
  fi
  _lock || return 1
  mkdir -p "$DATA/knowledge/facts" "$DATA/knowledge/lessons"
  if [ "$kind" = lesson ]; then _k_add_lesson "$id" "$body"; else _k_add_fact "$id" "$body" "$ttl"; fi
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
    local prev=""
    if [ "$(_squash "$(_body "$f")")" != "$(_squash "$body")" ]; then
      # newest wording wins (as with facts); the previous text is kept, never destroyed
      mkdir -p "$DATA/knowledge/lessons/superseded"
      prev="$(_uniq_dest "$DATA/knowledge/lessons/superseded/$id.prev.md")"
      cp "$f" "$prev"
    fi
    _fm_set "$f" seen "$seen"; _fm_set "$f" sessions "$sess"; _fm_set "$f" last_seen "$today"
    _set_body "$f" "$body"
    echo "reinforced lesson: $id (seen:$seen sessions:$sess)"
    [ -n "$prev" ] && echo "  wording updated; previous kept in lessons/superseded/$(basename "$prev")"
    if [ "$sess" -ge "$RELAY_GRADUATE_AT" ]; then
      echo "  → graduation-ready (sessions:$sess ≥ $RELAY_GRADUATE_AT): propose 'relay knowledge graduate $id'"
    fi
  else
    _write_lesson "$f" "$id" 1 1 "$today" "$today" "$(_provenance)" "$body"
    echo "added lesson: $id (seen:1 sessions:1)"
  fi
  return 0   # never let a false test/[-ge] make this function exit non-zero under set -e
}

k_list() {
  local kd="$DATA/knowledge" f id g
  _lock || return 1
  _kindex
  _unlock
  [ -d "$kd" ] || { echo "(no knowledge yet)"; return 0; }
  echo "Facts:"
  for f in "$kd"/facts/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"
    printf '  - %s (confirmed:%s)%s\n' "$id" "$(_fm "$f" confirmed)" \
      "$([ -f "$kd/facts/$id.conflict" ] && printf '  ⚠ conflict — resolve %s' "$id")"
  done
  echo "Lessons (active):"
  for f in "$kd"/lessons/*.md; do
    [ -e "$f" ] || continue
    printf '  - %s (seen:%s sessions:%s)\n' "$(_fm "$f" id)" "$(_fm "$f" seen)" "$(_fm "$f" sessions)"
  done
  if [ -d "$kd/lessons/graduated" ]; then
    echo "Lessons (graduated):"
    for f in "$kd"/lessons/graduated/*.md; do
      [ -e "$f" ] || continue
      id="$(_fm "$f" id)"; g="$(_fm "$f" graduated_to)"
      if [ -n "$g" ] && [ -f "$g" ] && grep -qF "<!-- relay:learned:$id -->" "$g"; then
        printf '  - %s → %s\n' "$id" "$g"
      else
        printf '  - %s  ⚠ DRIFT: graduated rule missing from %s — re-graduate or supersede\n' "$id" "$g"
      fi
    done
  fi
  local cf=0 cl=0
  cf="$(find "$kd/facts/cold" -name '*.md' 2>/dev/null | wc -l | tr -d ' ' || true)"
  cl="$(find "$kd/lessons/cold" -name '*.md' 2>/dev/null | wc -l | tr -d ' ' || true)"
  if [ "${cf:-0}" -gt 0 ] || [ "${cl:-0}" -gt 0 ]; then
    echo "Cold: $cf facts, $cl lessons (restore via: relay knowledge restore <id>)"
  fi
}

_block_remove() { # file id  (idempotent)
  local file="$1" id="$2" tmp
  [ -f "$file" ] || return 0
  tmp="$(mktemp)"
  awk -v id="$id" '
    BEGIN{ s="<!-- relay:learned:"id" -->"; e="<!-- /relay:learned:"id" -->"; skip=0 }
    { if($0==s){skip=1; next} if(skip==1){ if($0==e) skip=0; next } print }' "$file" > "$tmp"
  mv "$tmp" "$file"
}

k_ungraduate() {
  local id; id="$(_slugify "${1:-}")"
  local g="$DATA/knowledge/lessons/graduated/$id.md"
  _lock || return 1
  local target; target="$(_instruction_file)"
  _block_remove "$target" "$id"
  if [ -f "$g" ]; then
    mkdir -p "$DATA/knowledge/lessons/superseded"
    mv "$g" "$(_uniq_dest "$DATA/knowledge/lessons/superseded/$id.md")"
  fi
  _kindex
  _unlock
  echo "ungraduated: $id"
}

k_supersede() {
  local id; id="$(_slugify "${1:-}")"
  _lock || return 1
  local moved=0 kind
  for kind in facts lessons; do
    local f="$DATA/knowledge/$kind/$id.md"
    if [ -f "$f" ]; then
      mkdir -p "$DATA/knowledge/$kind/superseded"
      mv "$f" "$(_uniq_dest "$DATA/knowledge/$kind/superseded/$id.md")"
      rm -f "$DATA/knowledge/$kind/$id.conflict"
      moved=1
    fi
  done
  _kindex
  _unlock
  [ "$moved" = 1 ] && echo "superseded: $id" || { echo "relay: no active entry: $id" >&2; return 1; }
}

k_prune() {
  local apply=0; [ "${1:-}" = "--yes" ] && apply=1
  local kd="$DATA/knowledge" f id ttl last age limit stale=""
  [ -d "$kd/facts" ] || { echo "(no facts)"; return 0; }
  for f in "$kd"/facts/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"; ttl="$(_fm "$f" ttl)"; last="$(_fm "$f" last_confirmed)"
    age="$(_days_since "$last")"
    limit="$(_ttl_limit "$ttl")"
    [ "$age" -gt "$limit" ] && stale="$stale$id "
  done
  if [ -z "$stale" ]; then echo "(nothing stale)"; return 0; fi
  if [ "$apply" = 1 ]; then
    for id in $stale; do k_supersede "$id" >/dev/null; done
    echo "pruned: ${stale% }"
  else
    echo "Stale facts (past freshness window) — run 'relay knowledge prune --yes' to retire:"
    for id in $stale; do echo "  - $id"; done
  fi
}

_is_empty_body() { # no content, or only a stray flag token such as "--body" (an old add stored the flag as the body)
  local b; b="$(_squash "$(_body "$1")")"
  [ -z "$b" ] && return 0
  printf '%s' "$b" | grep -qE '^--[a-z][a-z-]*$'   # one token only: "--no-verify is banned" is real text
}

_compact_move() { # apply file dest label reason  (moved=1 propagates via bash dynamic scoping)
  if [ "$1" = 1 ]; then
    mkdir -p "$(dirname "$3")"
    mv "$2" "$(_uniq_dest "$3")"
    printf 'compact: %s -> %s (%s)\n' "$4" "$(basename "$(dirname "$3")")" "$5"
  else
    printf 'would compact: %s -> %s (%s)\n' "$4" "$(basename "$(dirname "$3")")" "$5"
  fi
  moved=1
}

_compact_cap() { # apply kind max
  local apply="$1" kind="$2" max="$3"
  local kd="$DATA/knowledge" f id metric age tmp total excess
  tmp="$(mktemp)"
  for f in "$kd"/"$kind"/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"
    if [ "$kind" = facts ]; then
      metric="$(_fm "$f" confirmed)"; age="$(_days_since "$(_fm "$f" last_confirmed)")"
    else
      metric="$(_fm "$f" seen)"; age="$(_days_since "$(_fm "$f" last_seen)")"
    fi
    printf '%06d\t%06d\t%s\n' "${metric:-1}" "${age:-0}" "$id" >> "$tmp"
  done
  total="$(grep -c . "$tmp" || true)"
  excess=$(( ${total:-0} - max ))
  if [ "$excess" -gt 0 ]; then
    # lowest metric first, then oldest (largest age); compact the bottom `excess`
    while IFS=$'\t' read -r _m _a id; do
      _compact_move "$apply" "$kd/$kind/$id.md" "$kd/$kind/cold/$id.md" "$kind/$id" "over cap ($total > $max)"
    done < <(sort -t$'\t' -k1,1n -k2,2nr "$tmp" | head -n "$excess")
  fi
  rm -f "$tmp"
  return 0
}

k_compact() {
  local apply=0; [ "${1:-}" = "--yes" ] && apply=1
  local kd="$DATA/knowledge" f id kind moved=0
  [ -d "$kd" ] || { echo "(no knowledge yet)"; return 0; }
  _lock || return 1
  # 1. empty sweep -> superseded (empties are write bugs, not knowledge)
  for kind in facts lessons; do
    for f in "$kd"/"$kind"/*.md; do
      [ -e "$f" ] || continue
      _is_empty_body "$f" || continue
      id="$(_fm "$f" id)"
      _compact_move "$apply" "$f" "$kd/$kind/superseded/$id.md" "$kind/$id" "empty or flag-only body"
    done
  done
  # 2. cold archive: unreinforced lessons older than RELAY_LESSON_COLD_DAYS
  for f in "$kd"/lessons/*.md; do
    [ -e "$f" ] || continue
    [ "$(_fm "$f" seen)" -le 1 ] 2>/dev/null || continue
    [ "$(_days_since "$(_fm "$f" last_seen)")" -gt "$RELAY_LESSON_COLD_DAYS" ] || continue
    id="$(_fm "$f" id)"
    _compact_move "$apply" "$f" "$kd/lessons/cold/$id.md" "lessons/$id" "seen:1 older than ${RELAY_LESSON_COLD_DAYS}d"
  done
  # 3. caps (facts never leave except via caps here or prune; lessons via caps)
  _compact_cap "$apply" facts "$RELAY_FACTS_MAX"
  _compact_cap "$apply" lessons "$RELAY_LESSONS_MAX"
  _kindex
  _unlock
  [ "$moved" = 0 ] && echo "(nothing to compact)"
  return 0
}

k_restore() {
  local id; id="$(_slugify "${1:-}")"
  local kd="$DATA/knowledge" kind src
  _lock || return 1
  for kind in facts lessons; do
    src="$kd/$kind/cold/$id.md"
    if [ -f "$src" ]; then
      mv "$src" "$(_uniq_dest "$kd/$kind/$id.md")"
      _kindex
      _unlock
      echo "restored: $id ($kind)"
      return 0
    fi
  done
  _unlock
  echo "relay: no cold entry: $id" >&2
  return 1
}

k_why() {
  local id; id="$(_slugify "${1:-}")"
  local f="" k
  for k in facts lessons; do [ -f "$DATA/knowledge/$k/$id.md" ] && { f="$DATA/knowledge/$k/$id.md"; break; }; done
  [ -n "$f" ] || { echo "relay: no entry: $id" >&2; return 1; }
  echo "--- entry ---"; cat "$f"
  local src; src="$(_fm "$f" source)"
  local hist="${src%%#*}"
  if [ -n "$hist" ] && [ -f "$DATA/$hist" ]; then
    echo; echo "--- came from $src ---"; sed -n '1,40p' "$DATA/$hist"
  elif [ -n "$hist" ]; then
    echo; echo "(source $src is no longer on disk: history keeps the last $RELAY_WINDOW session days)"
  fi
}

k_export() {
  local kd="$DATA/knowledge" f
  echo "# Relay knowledge pack — $(date +%F)"
  echo; echo "## Facts"
  for f in "$kd"/facts/*.md; do [ -e "$f" ] || continue; echo; echo "### $(_fm "$f" id)"; _body "$f"; done
  echo; echo "## Lessons"
  for f in "$kd"/lessons/*.md; do [ -e "$f" ] || continue; echo; echo "### $(_fm "$f" id)"; _body "$f"; done
}

main "$@"
