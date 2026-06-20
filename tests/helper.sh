# tests/helper.sh — zero-dependency assert library
assert_eq() { [ "$1" = "$2" ] || { echo "FAIL: expected [$2], got [$1]"; exit 1; }; }
assert_contains() { printf '%s' "$1" | grep -qF -- "$2" || { echo "FAIL: [$1] missing [$2]"; exit 1; }; }
assert_file() { [ -f "$1" ] || { echo "FAIL: missing file $1"; exit 1; }; }
assert_exit() { local want="$1"; shift; local got=0; "$@" >/dev/null 2>&1 || got=$?; [ "$got" = "$want" ] || { echo "FAIL: exit $got != $want for: $*"; exit 1; }; }
setup_tmp() { TMP="$(mktemp -d)"; DIR="$TMP/.session-log"; }
pass() { echo "PASS: ${1:-test}"; }
