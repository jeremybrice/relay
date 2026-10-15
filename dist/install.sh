emit_relay() { cat <<'RELAY_EOF'
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

_load_knowledge() {
  local kd="$DATA/knowledge" f id body conf last ttl age
  [ -d "$kd/facts" ] || [ -d "$kd/lessons" ] || return 0
  local out="" tmp sorted total shown block exp=0 conflicts=0

  # ---- FACTS: rank by confirmed, then recency ----
  tmp="$(mktemp)"
  for f in "$kd"/facts/*.md; do
    [ -e "$f" ] || continue
    id="$(_fm "$f" id)"; conf="$(_fm "$f" confirmed)"; last="$(_fm "$f" last_confirmed)"; ttl="$(_fm "$f" ttl)"
    body="$(_body "$f" | tr '\n' ' ')"
    age="$(_days_since "$last")"
    local lim; lim="$(_ttl_limit "$ttl")"
    [ "$age" -gt "$lim" ] && exp=$(( exp + 1 ))
    [ -f "$kd/facts/$id.conflict" ] && conflicts=$(( conflicts + 1 ))
    printf '%03d\t%09d\t- %s (confirmed:%s)\n' "${conf:-1}" "$(( 999999 - age ))" "$body" "${conf:-1}" >> "$tmp"
  done
  if [ -s "$tmp" ]; then
    total="$(grep -c . "$tmp" || true)"
    sorted="$(sort -t$'\t' -k1,1nr -k2,2nr "$tmp")"   # explicit numeric keys: confirmed desc, then recency desc
    block="$(printf '%s\n' "$sorted" | awk -v cap="$RELAY_FACTS_CAP" -F'\t' '
      { line=$3; n=split(line,w," "); if(words+n>cap && nl>0) next; words+=n; nl++; print line }')"
    shown="$(printf '%s\n' "$block" | grep -c . || true)"
    out="${out}## What this repo knows — facts"$'\n'
    [ "$shown" -lt "$total" ] && out="${out}⚠ $shown of $total facts shown — $(( total - shown )) not loaded may include load-bearing truths; open .session-log/knowledge/facts/"$'\n'
    out="${out}${block}"$'\n'
    [ "$exp" -gt 0 ] && out="${out}($exp fact(s) past freshness window — run: relay knowledge prune)"$'\n'
    [ "$conflicts" -gt 0 ] && out="${out}(⚠ $conflicts fact conflict(s) pending — run: relay knowledge resolve <id>)"$'\n'
    [ "$total" -gt "$RELAY_FACTS_MAX" ] && out="${out}(⚠ $total facts over cap $RELAY_FACTS_MAX — run: relay knowledge compact)"$'\n'
  fi
  rm -f "$tmp"

  # ---- LESSONS (active): rank by seen ----
  tmp="$(mktemp)"
  for f in "$kd"/lessons/*.md; do
    [ -e "$f" ] || continue
    body="$(_body "$f" | tr '\n' ' ')"
    printf '%05d\t- %s\n' "$(_fm "$f" seen)" "$body" >> "$tmp"
  done
  if [ -s "$tmp" ]; then
    total="$(grep -c . "$tmp" || true)"
    sorted="$(sort -t$'\t' -k1,1nr "$tmp")"   # explicit numeric key: seen desc
    block="$(printf '%s\n' "$sorted" | awk -v cap="$RELAY_LESSONS_CAP" -F'\t' '
      { line=$2; n=split(line,w," "); if(words+n>cap && nl>0) next; words+=n; nl++; print line }')"
    shown="$(printf '%s\n' "$block" | grep -c . || true)"
    out="${out}## What this repo knows — lessons"$'\n'
    [ "$shown" -lt "$total" ] && out="${out}⚠ $shown of $total lessons shown — open .session-log/knowledge/lessons/"$'\n'
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
  n="$(wc -w < "$latest" | tr -d ' ')"
  if [ "${n:-0}" -gt "$RELAY_WORD_CAP" ]; then
    out="$out$(awk -v cap="$RELAY_WORD_CAP" 'BEGIN{c=0}{c+=NF;print} c>=cap{print "\n…[truncated — open .session-log/latest.md for the full handoff]"; exit}' "$latest")"
  else
    out="$out$(cat "$latest")"
  fi
  local kblock; kblock="$(_load_knowledge)"
  [ -n "$kblock" ] && out="$out"$'\n\n'"$kblock"
  [ -f "$idx" ] && out="$out"$'\n\n'"$(cat "$idx")"
  out="$out"$'\n\nOpen .session-log/history/<date>.md for the full detail of an earlier day.'
  if [ "$format" = "codex" ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","systemMessage":"%s"}}\n' \
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
  if   [ -f "$PWD/CLAUDE.md" ]; then printf '%s' "$PWD/CLAUDE.md"
  elif [ -f "$PWD/AGENTS.md" ]; then printf '%s' "$PWD/AGENTS.md"
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
      *)        rest+=("$1");  shift;;
    esac
  done
  set -- ${rest[@]+"${rest[@]}"}
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

_is_empty_body() { local b; b="$(_body "$1" | tr -d '[:space:]')"; [ -z "$b" ]; }

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
      _compact_move "$apply" "$f" "$kd/$kind/superseded/$id.md" "$kind/$id" "empty body"
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
RELAY_EOF
}

emit_adapters() {
  mkdir -p ".relay/adapters/claude-code"
  emit__adapters_claude_code_CLAUDE_relay_md > ".relay/adapters/claude-code/CLAUDE.relay.md"
  mkdir -p ".relay/adapters/claude-code"
  emit__adapters_claude_code_relay_session_start_sh > ".relay/adapters/claude-code/relay-session-start.sh"
  mkdir -p ".relay/adapters/codex"
  emit__adapters_codex_AGENTS_relay_md > ".relay/adapters/codex/AGENTS.relay.md"
  mkdir -p ".relay/adapters/codex"
  emit__adapters_codex_hooks_relay_toml > ".relay/adapters/codex/hooks.relay.toml"
  mkdir -p ".relay/adapters/codex"
  emit__adapters_codex_relay_session_start_sh > ".relay/adapters/codex/relay-session-start.sh"
  mkdir -p ".relay/adapters/codex/skills/relay-compact"
  emit__adapters_codex_skills_relay_compact_SKILL_md > ".relay/adapters/codex/skills/relay-compact/SKILL.md"
  mkdir -p ".relay/adapters/codex/skills/relay-learn"
  emit__adapters_codex_skills_relay_learn_SKILL_md > ".relay/adapters/codex/skills/relay-learn/SKILL.md"
  mkdir -p ".relay/adapters/codex/skills/session-save"
  emit__adapters_codex_skills_session_save_SKILL_md > ".relay/adapters/codex/skills/session-save/SKILL.md"
  mkdir -p ".relay/adapters/cursor"
  emit__adapters_cursor_AGENTS_relay_md > ".relay/adapters/cursor/AGENTS.relay.md"
  mkdir -p ".relay/adapters/grok"
  emit__adapters_grok_AGENTS_relay_md > ".relay/adapters/grok/AGENTS.relay.md"
  mkdir -p ".relay/adapters/grok"
  emit__adapters_grok_hooks_relay_json > ".relay/adapters/grok/hooks.relay.json"
  mkdir -p ".relay/adapters/grok"
  emit__adapters_grok_relay_session_start_sh > ".relay/adapters/grok/relay-session-start.sh"
  mkdir -p ".relay/adapters/opencode"
  emit__adapters_opencode_AGENTS_relay_md > ".relay/adapters/opencode/AGENTS.relay.md"
  mkdir -p ".relay/adapters/opencode/commands"
  emit__adapters_opencode_commands_relay_compact_md > ".relay/adapters/opencode/commands/relay-compact.md"
  mkdir -p ".relay/adapters/opencode/commands"
  emit__adapters_opencode_commands_relay_learn_md > ".relay/adapters/opencode/commands/relay-learn.md"
  mkdir -p ".relay/adapters/opencode/commands"
  emit__adapters_opencode_commands_session_save_md > ".relay/adapters/opencode/commands/session-save.md"
  mkdir -p ".relay/adapters/opencode"
  emit__adapters_opencode_instructions_relay_jsonc > ".relay/adapters/opencode/instructions.relay.jsonc"
  mkdir -p ".relay/adapters/skills/relay-compact"
  emit__adapters_skills_relay_compact_SKILL_md > ".relay/adapters/skills/relay-compact/SKILL.md"
  mkdir -p ".relay/adapters/skills/relay-learn"
  emit__adapters_skills_relay_learn_SKILL_md > ".relay/adapters/skills/relay-learn/SKILL.md"
  mkdir -p ".relay/adapters/skills/session-save"
  emit__adapters_skills_session_save_SKILL_md > ".relay/adapters/skills/session-save/SKILL.md"
}

emit__adapters_claude_code_CLAUDE_relay_md() { cat <<'RELAY_EOF'
<!-- adapters/claude-code/CLAUDE.relay.md -->
## Relay — session handoff (Claude Code)
When the user signals the session is wrapping up ("done for today", "let's
continue tomorrow", or a task completes and we're winding down), run
`/session-save` to persist a Relay handoff. If unsure the session is ending,
offer it in one line.
At wrap-up, also capture durable facts/lessons with `/relay-learn` (or inline
`knowledge add`), and surface any graduation-ready lesson for the user to approve.
If knowledge is over cap, offer `/relay-compact` in one line — never run it unasked.
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
## Relay — session handoff (Codex)
At the START of a session, read `.session-log/latest.md` and `.session-log/index.md`
first — they are the last agent's handoff. When wrapping up ("done for today" /
"continue tomorrow"), run `$session-save` to persist a new handoff; offer it if unsure.
At wrap-up, also capture durable facts/lessons with `$relay-learn` (or inline
`knowledge add`), and surface any graduation-ready lesson for the user to approve.
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

emit__adapters_codex_skills_relay_compact_SKILL_md() { cat <<'RELAY_EOF'
<!-- adapters/codex/skills/relay-compact/SKILL.md -->
---
name: relay-compact
description: Consolidate Relay knowledge — sweep empties, archive stale, merge duplicates (human-gated)
---
Run the Relay knowledge consolidation cycle. Mechanical fixes first, then a
human-gated semantic pass. Use `"${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh"`
as `R` and `--dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log"` as `D` below.

1. Mechanical pass. Show each dry run to the user, then apply:
   `R knowledge compact D` (dry run — show the user), then
   `R knowledge compact --yes D`; then `R knowledge prune D` (dry run — show
   the user), then `R knowledge prune --yes D`.
2. Read the full surviving corpus: `R knowledge export D`.
3. Build a consolidation plan:
   - Merge groups: duplicate/overlapping entries → one entry per group. Keep
     the most descriptive existing slug, rewrite the body to capture the
     union, name the absorbed ids.
   - Rewrites: bodies stale against the current codebase → corrected body.
     VERIFY against the repo before declaring anything stale — never from
     memory alone.
   - Graduations: lessons with sessions >= 3 that are durable repo rules →
     propose `knowledge graduate <id>`.
   - Deletions: entries that no longer reflect the codebase with no merge
     target → propose `knowledge supersede <id>`.
4. Present the plan to the user. Apply NOTHING until approved. Graduations
   additionally need per-item user OK.
5. Apply only through existing primitives:
   - merge/rewrite: `R knowledge add --fact|--lesson --id <kept-slug> '<rewritten body>' D`
     (reinforces the kept id, preserving its first_seen provenance)
   - absorbed/deleted ids: `R knowledge supersede <id> D`
   - approved graduations: `R knowledge graduate <id> D`
6. Report final counts: `R knowledge list D`. (The session-start hook picks up
   the compacted store next session — no snapshot refresh needed.)

Invariants:
- Never invent knowledge — merges only reword existing bodies.
- Never merge across kinds (facts = durable truths; lessons = behavioral patterns).
- Prefer reinforcing the oldest entry in a merge group (keeps first_seen).
RELAY_EOF
}

emit__adapters_codex_skills_relay_learn_SKILL_md() { cat <<'RELAY_EOF'
<!-- adapters/codex/skills/relay-learn/SKILL.md -->
---
name: relay-learn
description: Record a durable fact or lesson about this repo into Relay knowledge
---
Capture one durable piece of knowledge about THIS repo for future sessions.

1. Fact = durable repo truth; Lesson = behavioral pattern ("when X, prefer Y").
2. For a fact, check for a match first (reuse the id, don't duplicate):

   ```bash
   "${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --fact --near '<fact text>' \
     --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log"
   ```
3. Write it with a short stable kebab-case `--id` (a fact reuses any id surfaced above):

   ```bash
   "${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --fact --id <slug> '<fact text>' \
     --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log"
   # or a lesson:
   "${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --lesson --id <slug> '<lesson text>' \
     --dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log"
   ```
4. If a lesson is graduation-ready, offer to `knowledge graduate <slug>` — only with the user's okay.
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
4. Then capture durable knowledge (skip if none): facts via
   `knowledge add --fact --near` then `--fact --id <slug>`; lessons via
   `knowledge add --lesson --id <slug>`, using `"${CODEX_PROJECT_DIR:-$PWD}/.relay/relay.sh"`
   and `--dir "${CODEX_PROJECT_DIR:-$PWD}/.session-log"`. Offer graduation only when prompted and approved.
If `knowledge list` reports counts over cap (or the session-start load warned
"(⚠ N ... over cap ...)"), offer `$relay-compact` in one line — never run it
unasked.
RELAY_EOF
}

emit__adapters_cursor_AGENTS_relay_md() { cat <<'RELAY_EOF'
<!-- adapters/cursor/AGENTS.relay.md -->
## Relay — session handoff (Cursor)
At the START of a session, read `.session-log/latest.md` and `.session-log/index.md`
if they exist — they are the last agent's handoff. If missing, continue.
When the user signals the session is wrapping up ("done for today", "let's
continue tomorrow", or a task completes and we're winding down), run the
`session-save` skill to persist a Relay handoff. If unsure the session is ending,
offer it in one line.
At wrap-up, also capture durable facts/lessons with the `relay-learn` skill (or inline
`knowledge add`), and surface any graduation-ready lesson for the user to approve.
If knowledge is over cap, offer the `relay-compact` skill in one line.
RELAY_EOF
}

emit__adapters_grok_AGENTS_relay_md() { cat <<'RELAY_EOF'
<!-- adapters/grok/AGENTS.relay.md -->
## Relay — session handoff (Grok Build)
At the START of a session, read `.session-log/latest.md` and `.session-log/index.md`
if they exist — they are the last agent's handoff. If missing, continue.
When the user signals the session is wrapping up ("done for today", "let's
continue tomorrow", or a task completes and we're winding down), run the
`session-save` skill to persist a Relay handoff. If unsure the session is ending,
offer it in one line.
At wrap-up, also capture durable facts/lessons with the `relay-learn` skill (or inline
`knowledge add`), and surface any graduation-ready lesson for the user to approve.
If knowledge is over cap, offer the `relay-compact` skill in one line.
RELAY_EOF
}

emit__adapters_grok_hooks_relay_json() { cat <<'RELAY_EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "bash .relay/adapters/grok/relay-session-start.sh", "timeout": 10 }
        ]
      }
    ]
  }
}
RELAY_EOF
}

emit__adapters_grok_relay_session_start_sh() { cat <<'RELAY_EOF'
#!/usr/bin/env bash
# Grok SessionStart hook → emits {"systemMessage":<handoff>} JSON (Grok reads only
# a top-level systemMessage from observe-only events). AGENTS.md is the fallback.
set -euo pipefail
ROOT="${GROK_WORKSPACE_ROOT:-$PWD}"
[ -x "$ROOT/.relay/relay.sh" ] || exit 0
"$ROOT/.relay/relay.sh" load --dir "$ROOT/.session-log" --format grok 2>/dev/null || true
exit 0
RELAY_EOF
}

emit__adapters_opencode_AGENTS_relay_md() { cat <<'RELAY_EOF'
<!-- adapters/opencode/AGENTS.relay.md -->
## Relay — session handoff (OpenCode)
At the START of a session, the last handoff + active knowledge load automatically
via the `instructions` entry in `opencode.json` (from
`.session-log/relay-instructions.md`). If that file is missing or empty, fall back
to reading `.session-log/latest.md` and `.session-log/index.md` directly.
When the user signals the session is wrapping up ("done for today", "let's
continue tomorrow", or a task completes and we're winding down), run
`/session-save` to persist a Relay handoff. If unsure the session is ending,
offer it in one line.
At wrap-up, also capture durable facts/lessons with `/relay-learn` (or inline
`knowledge add`), and surface any graduation-ready lesson for the user to approve.
RELAY_EOF
}

emit__adapters_opencode_commands_relay_compact_md() { cat <<'RELAY_EOF'
<!-- adapters/opencode/commands/relay-compact.md -->
---
description: Consolidate Relay knowledge — sweep empties, archive stale, merge duplicates (human-gated)
---
Run the Relay knowledge consolidation cycle. Mechanical fixes first, then a
human-gated semantic pass. Use `"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh"`
as `R` and `--dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log"` as `D` below.

1. Mechanical pass. Show each dry run to the user, then apply:

   ```bash
   R knowledge compact D          # dry run — show the user
   R knowledge compact --yes D
   R knowledge prune D            # dry run — show the user
   R knowledge prune --yes D
   ```
2. Read the full surviving corpus: `R knowledge export D`.
3. Build a consolidation plan:
   - Merge groups: duplicate/overlapping entries → one entry per group. Keep
     the most descriptive existing slug, rewrite the body to capture the
     union, name the absorbed ids.
   - Rewrites: bodies stale against the current codebase → corrected body.
     VERIFY against the repo before declaring anything stale — never from
     memory alone.
   - Graduations: lessons with sessions >= 3 that are durable repo rules →
     propose `knowledge graduate <id>`.
   - Deletions: entries that no longer reflect the codebase with no merge
     target → propose `knowledge supersede <id>`.
4. Present the plan to the user. Apply NOTHING until approved. Graduations
   additionally need per-item user OK.
5. Apply only through existing primitives:
   - merge/rewrite: `R knowledge add --fact|--lesson --id <kept-slug> '<rewritten body>' D`
     (reinforces the kept id, preserving its first_seen provenance)
   - absorbed/deleted ids: `R knowledge supersede <id> D`
   - approved graduations: `R knowledge graduate <id> D`
6. Refresh the snapshot opencode auto-loads next session:

   ```bash
   R load D > "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log/relay-instructions.md"
   ```
7. Report final counts: `R knowledge list D`.

Invariants:
- Never invent knowledge — merges only reword existing bodies.
- Never merge across kinds (facts = durable truths; lessons = behavioral patterns).
- Prefer reinforcing the oldest entry in a merge group (keeps first_seen).
RELAY_EOF
}

emit__adapters_opencode_commands_relay_learn_md() { cat <<'RELAY_EOF'
<!-- adapters/opencode/commands/relay-learn.md -->
---
description: Record a durable fact or lesson about this repo into Relay knowledge
---
Capture a single durable piece of knowledge about THIS repo for future sessions.

1. Decide the kind:
   - **Fact** — a durable truth about the repo (a command, a path, a gotcha).
   - **Lesson** — a behavioral pattern ("when X, prefer Y, because Z").
2. For a fact, first check for an existing match so you reuse its id instead of
   duplicating:

   ```bash
   "${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --fact --near '<the fact text>' \
     --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log"
   ```
3. Write it (reuse a surfaced id, or coin a short stable kebab-case slug). Add
   `--ttl <days>` to a fact that is only true for a while (e.g. the current sprint);
   omit it for durable truths:

   ```bash
   "${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --fact --id <slug> '<fact text>' \
     --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log"
   # time-bound fact: ... knowledge add --fact --id current-sprint --ttl 14 '...' --dir ...
   # or a lesson:
   "${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" knowledge add --lesson --id <slug> '<lesson text>' \
     --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log"
   ```
4. Refresh the snapshot opencode auto-loads next session so the new knowledge
   is in context the moment the next session starts:

   ```bash
   "${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" load --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" \
     > "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log/relay-instructions.md"
   ```
5. If the tool reports a lesson is graduation-ready, offer (one line) to run
   `knowledge graduate <slug>` — never graduate without the user's okay.
RELAY_EOF
}

emit__adapters_opencode_commands_session_save_md() { cat <<'RELAY_EOF'
<!-- adapters/opencode/commands/session-save.md -->
---
description: Save a Relay handoff so the next opencode session can pick up where you left off
---
Persist a Relay handoff for the next agent.

1. Author the six sections as concise markdown — `## Summary`, `## Changed`,
   `## Decisions`, `## Next`, `## Watch out`, `## Open questions` — naming real
   files/paths and dated facts. Compose a one-line digest.
2. Persist it. The script owns all file writes, rotation, and locking:

   ```bash
   printf '%s\n' '<<the six sections as markdown>>' \
     | "${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" save \
         --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" \
         --digest '<<one-line digest>>'
   ```
3. Reply: "Handoff saved for the next session."
4. Refresh the snapshot opencode auto-loads next session via `opencode.json`'s
   `instructions` field, so the new handoff is in context the moment the next
   session starts:

   ```bash
   "${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh" load --dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log" \
     > "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log/relay-instructions.md"
   ```
5. Then capture durable knowledge from this session (skip if none): for each
   permanent repo truth run `knowledge add --fact --near` then `--fact --id <slug>`;
   for each behavioral lesson run `knowledge add --lesson --id <slug>`. Use
   `"${OPENCODE_PROJECT_DIR:-$PWD}/.relay/relay.sh"` and
   `--dir "${OPENCODE_PROJECT_DIR:-$PWD}/.session-log"`. Re-run the step-4 load
   after the knowledge writes so the snapshot stays current. If the tool says a
   lesson is graduation-ready, offer graduation in one line.
6. If `knowledge list` reports counts over cap (or step 4's load warned
   "(⚠ N ... over cap ...)"), offer `$relay-compact` in one line — never run
   it unasked.
RELAY_EOF
}

emit__adapters_opencode_instructions_relay_jsonc() { cat <<'RELAY_EOF'
// adapters/opencode/instructions.relay.jsonc
// Merge this entry into opencode.json's `instructions` array (idempotent):
//   .session-log/relay-instructions.md is a snapshot of the last handoff +
//   active knowledge + index, refreshed by /session-save and /relay-learn.
//   opencode loads it as system context at every session start — the static
//   equivalent of Claude Code's SessionStart hook / Codex's hookSpecificOutput.
{
  "$schema": "https://opencode.ai/config.json",
  "instructions": [".session-log/relay-instructions.md"]
}
RELAY_EOF
}

emit__adapters_skills_relay_compact_SKILL_md() { cat <<'RELAY_EOF'
---
name: relay-compact
description: Consolidate Relay knowledge — sweep empties, archive stale, merge duplicates (human-gated)
---

Run the Relay knowledge consolidation cycle. Mechanical fixes first, then a
human-gated semantic pass. Use `"$PWD/.relay/relay.sh"` as `R` and
`--dir "$PWD/.session-log"` as `D` below.

1. Mechanical pass. Show each dry run to the user, then apply:

   ```bash
   R knowledge compact D
   R knowledge compact --yes D
   R knowledge prune D
   R knowledge prune --yes D
   ```

2. Read the full surviving corpus: `R knowledge export D`.
3. Build a consolidation plan:
   - Merge groups: duplicate/overlapping entries → one entry per group. Keep
     the most descriptive existing slug, rewrite the body to capture the union,
     name the absorbed ids.
   - Rewrites: bodies stale against the current codebase → corrected body.
     VERIFY against the repo before declaring anything stale — never from
     memory alone.
   - Graduations: lessons with sessions >= 3 that are durable repo rules →
     propose `knowledge graduate <id>`.
   - Deletions: entries that no longer reflect the codebase with no merge
     target → propose `knowledge supersede <id>`.
4. Present the plan to the user. Apply NOTHING until approved. Graduations
   additionally need per-item user OK.
5. Apply only through existing primitives:
   - merge/rewrite: `R knowledge add --fact|--lesson --id <kept-slug> '<rewritten body>' D`
   - absorbed/deleted ids: `R knowledge supersede <id> D`
   - approved graduations: `R knowledge graduate <id> D`
6. Report final counts: `R knowledge list D`. The next session picks up the
   compacted store when it reads `.session-log/`. No snapshot refresh.

Invariants:
- Never invent knowledge — merges only reword existing bodies.
- Never merge across kinds (facts = durable truths; lessons = behavioral patterns).
- Prefer reinforcing the oldest entry in a merge group (keeps first_seen).
RELAY_EOF
}

emit__adapters_skills_relay_learn_SKILL_md() { cat <<'RELAY_EOF'
---
name: relay-learn
description: Record a durable fact or lesson about this repo into Relay knowledge
---

Capture a single durable piece of knowledge about THIS repo for future sessions.

1. Decide the kind:
   - **Fact** — a durable truth about the repo (a command, a path, a gotcha).
   - **Lesson** — a behavioral pattern ("when X, prefer Y, because Z").
2. For a fact, first check for an existing match so you reuse its id instead of
   duplicating:

   ```bash
   "$PWD/.relay/relay.sh" knowledge add --fact --near '<the fact text>' \
     --dir "$PWD/.session-log"
   ```

3. Write it (reuse a surfaced id, or coin a short stable kebab-case slug). Add
   `--ttl <days>` to a fact that is only true for a while; omit it for durable
   truths:

   ```bash
   "$PWD/.relay/relay.sh" knowledge add --fact --id <slug> '<fact text>' \
     --dir "$PWD/.session-log"
   "$PWD/.relay/relay.sh" knowledge add --lesson --id <slug> '<lesson text>' \
     --dir "$PWD/.session-log"
   ```

4. If the tool reports a lesson is graduation-ready, offer (one line) to run
   `knowledge graduate <slug>` — never graduate without the user's okay.

Do not write `.session-log/relay-instructions.md`. Session start reads
`.session-log/latest.md` and `.session-log/index.md` only.
RELAY_EOF
}

emit__adapters_skills_session_save_SKILL_md() { cat <<'RELAY_EOF'
---
name: session-save
description: Save a Relay handoff so the next session can pick up where you left off
---

Persist a Relay handoff for the next agent.

1. Author the six sections as concise markdown — `## Summary`, `## Changed`,
   `## Decisions`, `## Next`, `## Watch out`, `## Open questions` — naming real
   files/paths and dated facts. Compose a one-line digest.
2. Persist it. The script owns all file writes, rotation, and locking:

   ```bash
   printf '%s\n' '<<the six sections as markdown>>' \
     | "$PWD/.relay/relay.sh" save \
         --dir "$PWD/.session-log" \
         --digest '<<one-line digest>>'
   ```

3. Reply: "Handoff saved for the next session."
4. Then capture durable knowledge from this session (skip if none) using the
   `relay-learn` skill, or call `"$PWD/.relay/relay.sh"` `knowledge add` with
   `--dir "$PWD/.session-log"`. If the tool says a lesson is graduation-ready,
   offer graduation in one line. Never graduate without the user's okay.
5. If `knowledge list` reports counts over cap (or a load warned
   "(⚠ N ... over cap ...)"), offer `relay-compact` in one line.
   Never run it unasked.

Do not write `.session-log/relay-instructions.md`. Session start reads
`.session-log/latest.md` and `.session-log/index.md` only.
RELAY_EOF
}

emit_smoke_compact() { cat <<'RELAY_EOF'
#!/usr/bin/env bash
# smoke-compact.sh — contract test for relay knowledge compact/restore/empty-body guard.
# Runs against a throwaway --dir fixture; never touches the real .session-log.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RELAY="$HERE/../relay.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DATA="$TMP/.session-log"
mkdir -p "$DATA/knowledge/facts" "$DATA/knowledge/lessons"
fails=0
t() { # label expected actual
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; else printf 'FAIL - %s (want %s got %s)\n' "$1" "$2" "$3"; fails=$((fails+1)); fi
}

old="2000-01-01"
today="$(date +%F)"

lesson() { # file id seen last [body]
  printf -- '---\nid: %s\nkind: lesson\nseen: %s\nsessions: 1\nfirst_seen: %s\nlast_seen: %s\nsource: test\nstatus: active\ngraduated_to: null\n---\n%s\n' \
    "$2" "$3" "$4" "$4" "${5:-}" > "$1"
}
fact() { # file id confirmed last [body]
  printf -- '---\nid: %s\nkind: fact\nconfirmed: %s\nfirst_seen: %s\nlast_confirmed: %s\nttl: none\nsource: test\nstatus: active\n---\n%s\n' \
    "$2" "$3" "$4" "$4" "${5:-}" > "$1"
}

# --- fixture ---
lesson "$DATA/knowledge/lessons/empty-lesson.md"    empty-lesson   1 "$today" ""
fact   "$DATA/knowledge/facts/empty-fact.md"        empty-fact     1 "$today" ""
lesson "$DATA/knowledge/lessons/stale-seen1.md"     stale-seen1    1 "$old"    "body for stale-seen1"
lesson "$DATA/knowledge/lessons/fresh-seen1.md"     fresh-seen1    1 "$today"  "body for fresh-seen1"
lesson "$DATA/knowledge/lessons/old-reinforced.md"  old-reinforced 3 "$old"    "body for old-reinforced"
fact   "$DATA/knowledge/facts/keep-fact.md"         keep-fact      2 "$old"    "body for keep-fact"
# load only emits when a handoff exists (cmd_load early-returns without latest.md)
printf -- '---\ndate: %s\nsession: 1\ndigest: "fixture"\n---\nfixture handoff body\n' "$today" > "$DATA/latest.md"

# 1. empty-body add is rejected and writes nothing
if "$RELAY" knowledge add --lesson --id should-not-exist --dir "$DATA" >/dev/null 2>&1; then
  t "empty-body add rejected" "nonzero" "zero"
else
  t "empty-body add rejected" "nonzero" "nonzero"
fi
[ ! -f "$DATA/knowledge/lessons/should-not-exist.md" ] && r="absent" || r="present"
t "empty-body add wrote nothing" "absent" "$r"

# 2. compact dry run reports and changes nothing
out="$("$RELAY" knowledge compact --dir "$DATA" 2>/dev/null)" || true
echo "$out" | grep -q "would compact: lessons/empty-lesson" && r=yes || r=no; t "dry run flags empty lesson" yes "$r"
echo "$out" | grep -q "would compact: lessons/stale-seen1" && r=yes || r=no; t "dry run flags stale seen:1 lesson" yes "$r"
[ -f "$DATA/knowledge/lessons/empty-lesson.md" ] && r=yes || r=no; t "dry run changes nothing" yes "$r"

# 3. compact --yes moves entries to the right destinations
"$RELAY" knowledge compact --yes --dir "$DATA" >/dev/null 2>&1 || true
[ -f "$DATA/knowledge/lessons/superseded/empty-lesson.md" ] && r=yes || r=no; t "empty lesson -> superseded" yes "$r"
[ -f "$DATA/knowledge/facts/superseded/empty-fact.md" ] && r=yes || r=no; t "empty fact -> superseded" yes "$r"
[ -f "$DATA/knowledge/lessons/cold/stale-seen1.md" ] && r=yes || r=no; t "stale seen:1 lesson -> cold" yes "$r"
[ -f "$DATA/knowledge/lessons/fresh-seen1.md" ] && r=yes || r=no; t "fresh seen:1 lesson kept" yes "$r"
[ -f "$DATA/knowledge/lessons/old-reinforced.md" ] && r=yes || r=no; t "old reinforced lesson kept" yes "$r"
[ -f "$DATA/knowledge/facts/keep-fact.md" ] && r=yes || r=no; t "old fact kept (prune owns fact staleness)" yes "$r"
grep -q stale-seen1 "$DATA/knowledge/index.md" && r=no || r=yes; t "index excludes compacted entries" yes "$r"

# 4. caps: RELAY_LESSONS_MAX=2 with 3 active lessons -> lowest-ranked goes cold
lesson "$DATA/knowledge/lessons/cap-victim.md" cap-victim 1 "$today" "body for cap-victim"
RELAY_LESSONS_MAX=2 "$RELAY" knowledge compact --yes --dir "$DATA" >/dev/null 2>&1 || true
n="$(ls -1 "$DATA/knowledge/lessons"/*.md 2>/dev/null | wc -l | tr -d ' ')"
t "cap trims active lessons to RELAY_LESSONS_MAX" "2" "$n"
[ -f "$DATA/knowledge/lessons/old-reinforced.md" ] && r=yes || r=no; t "cap keeps highest-seen entry" yes "$r"
[ -f "$DATA/knowledge/lessons/cold/cap-victim.md" ] && r=yes || r=no; t "cap colds lowest-ranked entry" yes "$r"

# 5. restore returns a cold entry to active
"$RELAY" knowledge restore stale-seen1 --dir "$DATA" >/dev/null 2>&1 || true
[ -f "$DATA/knowledge/lessons/stale-seen1.md" ] && r=yes || r=no; t "restore returns cold entry" yes "$r"

# 6. loader output includes restored entries and excludes cold/superseded ones
out="$("$RELAY" load --dir "$DATA" 2>/dev/null)" || true
echo "$out" | grep -q "body for stale-seen1" && r=yes || r=no; t "loader shows restored entry" yes "$r"
echo "$out" | grep -q "body for cap-victim" && r=yes || r=no; t "loader hides cold entry" no "$r"

# 7. over-cap nudge appears in load output
out="$(RELAY_LESSONS_MAX=1 "$RELAY" load --dir "$DATA" 2>/dev/null)" || true
echo "$out" | grep -q "over cap" && r=yes || r=no; t "load nudges when over cap" yes "$r"

if [ "$fails" -gt 0 ]; then echo "SMOKE FAIL ($fails)"; exit 1; fi
echo "SMOKE OK"
RELAY_EOF
}

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
  # idempotent per adapter: each source's first line is its own header comment
  grep -qF "$(head -n 1 "$src")" "$file" 2>/dev/null && return 0
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
  for f in opencode.jsonc opencode.json; do [ -f "$f" ] && { cfg="$f"; break; }; done
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
