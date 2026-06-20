#!/usr/bin/env bash
# bundle.sh — concatenate sources into dist/install.sh (embedded heredocs).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dist
OUT="dist/install.sh"

emit_heredoc() { # varfunc, path
  local fn="$1" path="$2"
  printf '%s() { cat <<'"'"'RELAY_EOF'"'"'\n' "$fn"
  cat "$path"
  printf '\nRELAY_EOF\n}\n\n'
}

{
  # 1. emitter functions that reproduce each source file
  emit_heredoc emit_relay relay.sh
  printf 'emit_adapters() {\n'
  while IFS= read -r f; do
    rel="${f#./}"
    printf '  mkdir -p ".relay/%s"\n' "$(dirname "$rel")"
    printf '  emit__%s > ".relay/%s"\n' "$(echo "$rel" | tr './-' '___')" "$rel"
  done < <(cd . && find adapters -type f | sort)
  printf '}\n\n'
  while IFS= read -r f; do
    rel="${f#./}"
    emit_heredoc "emit__$(echo "$rel" | tr './-' '___')" "$rel"
  done < <(cd . && find adapters -type f | sort)
  # 2. the installer body (skips its own `emit_*`-only `--from` branch when bundled)
  cat install.sh
} > "$OUT"
chmod +x "$OUT"
echo "wrote $OUT"
