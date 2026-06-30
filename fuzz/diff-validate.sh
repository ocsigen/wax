#!/usr/bin/env bash
#
# diff-validate.sh [count] [bytes]
#
# Differential VALIDATION oracle: it tests wax's type checker directly against
# the WebAssembly *reference interpreter*, rather than indirectly through the
# round-trip / execution oracles. For each generated module the reference
# interpreter accepts, decompile it to wax and compare verdicts:
#
#   OVER_REJECT — the reference accepts the module, but wax rejects its faithful
#                 decompilation. wax's typing is too strict (a completeness gap):
#                 a valid module that wax refuses to round-trip.
#   UNSOUND     — wax accepts the decompiled wax, but the binary it re-emits is
#                 rejected by the reference. wax's typing is too lenient (it let
#                 through something that does not yield valid wasm).
#   CRASH       — wax crashed (uncaught exception, signal, timeout) on either step.
#
# The ground truth is the spec REFERENCE interpreter (REF, default
# ~/sources/Wasm/interpreter/wasm) — not wasm-tools — and both the too-strict and
# too-lenient directions are checked in one pass. Modules the reference rejects
# are skipped (invalid input is not what we are differencing here).
#
# Usage: diff-validate.sh [count] [bytes]   (defaults: 2000 modules, 2048 bytes)
#        REF=/path/to/wasm  diff-validate.sh ...
# Failing modules are saved under fuzz/diff-findings/.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REF="${REF:-$HOME/sources/Wasm/interpreter/wasm}"
COUNT="${1:-2000}"
BYTES="${2:-2048}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
KEEP="$ROOT/fuzz/diff-findings"
mkdir -p "$KEEP"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT

# Reference-interpreter verdict on a binary: 0 = valid, non-zero = rejected.
ref_validate() { "$REF" -d "$1" >/dev/null 2>&1; }
export -f ref_validate

# Run one module through the differential. Writes a finding line to $RESULTS/$i
# and prints a progress byte (. ok, F finding, s could-not-generate, x ref-reject).
diff_one() {
  local i="$1" seed mod wax bin v ERRLOG
  seed="$(mktemp)"; mod="$(mktemp --suffix=.wasm)"
  wax="$(mktemp --suffix=.wax)"; bin="$(mktemp --suffix=.wasm)"
  ERRLOG="$(mktemp)"   # per-worker; classify_wax writes the diagnostic here
  trap 'rm -f "$seed" "$mod" "$wax" "$bin" "$ERRLOG"' RETURN
  head -c "$BYTES" /dev/urandom >"$seed"
  "$WASM_TOOLS" smith $SMITH_FLAGS "$seed" -o "$mod" 2>/dev/null || { printf 's' >&2; return 0; }
  # Only difference modules the reference accepts.
  ref_validate "$mod" || { printf 'x' >&2; return 0; }

  # Step 1: decompile to wax.
  v="$(classify_wax -i wasm -f wax "$mod" -o "$wax")"
  case "$v" in
    crash:*) save "$i" "$mod" "decompile $v"; printf 'F' >&2; return 0 ;;
    rejected) save "$i" "$mod" "reference accepts but wax cannot decompile it"; printf 'F' >&2; return 0 ;;
  esac

  # Step 2: wax's own verdict on the decompiled wax (its type checker).
  v="$(classify_wax -i wax -f wasm "$wax" -o "$bin" --validate)"
  case "$v" in
    crash:*) save "$i" "$mod" "recompile $v"; printf 'F' >&2; return 0 ;;
    rejected) save "$i" "$mod" "OVER_REJECT: reference accepts, wax rejects its decompilation"; printf 'F' >&2; return 0 ;;
  esac

  # Step 3: wax accepted — the emitted binary must satisfy the reference too.
  if ! ref_validate "$bin"; then
    save "$i" "$mod" "UNSOUND: wax accepts but the reference rejects its emitted binary"
    printf 'F' >&2; return 0
  fi
  printf '.' >&2
}
export -f diff_one

# Persist a failing module and record its finding line.
save() {
  local i="$1" mod="$2" msg="$3" keep="$KEEP/diff-$1.wasm"
  cp "$mod" "$keep"
  echo "FINDING	$msg	$keep" >"$RESULTS/$i"
}
export -f save
export -f classify_wax   # defined in lib.sh; diff_one calls it in the xargs subshell
export WAX WASM_TOOLS TIMEOUT SMITH_FLAGS REF BYTES KEEP RESULTS

rm -f "$KEEP"/*.wasm 2>/dev/null
seq 1 "$COUNT" | xargs -P "$JOBS" -I{} bash -c 'diff_one "$@"' _ {}
echo >&2

echo "================= differential validation report ================="
n="$(cat "$RESULTS"/* 2>/dev/null | grep -c . || true)"
echo "modules checked: $COUNT"
echo "findings: $n"
if [ "$n" -gt 0 ]; then
  echo
  cat "$RESULTS"/* | sort | sed 's/^/  /'
fi
[ "$n" -gt 0 ] && exit 1
exit 0
