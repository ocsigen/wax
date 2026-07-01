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
# The per-module oracle is latency-bound — smith + two reference-interpreter runs
# + two wax forks, each mostly fork/exec/IO wait — so at one worker per core the
# cores sit ~80% idle. Oversubscribe (like smith.sh); ~4x the core count is the
# sweet spot, plateauing around 6x. Raise JOBS further on a roomy machine.
JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
KEEP="$ROOT/fuzz/diff-findings"
mkdir -p "$KEEP"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"  # run against a snapshot so a concurrent rebuild can't corrupt workers

# Reference-interpreter verdict on a binary: 0 = valid, non-zero = rejected.
ref_validate() { "$REF" -d "$1" >/dev/null 2>&1; }

# Run one module through the differential. Writes a finding line to $RESULTS/$i
# and prints a progress byte (. ok, F finding, s could-not-generate, x ref-reject).
# The temp files ($seed/$mod/$wax/$bin/$ERRLOG) belong to the calling worker and
# are reused across its modules, so no per-module process is spawned to make them.
diff_one() {
  local i="$1" v
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

# Persist a failing module and record its finding line.
save() {
  local i="$1" mod="$2" msg="$3" keep="$KEEP/diff-$1.wasm"
  cp "$mod" "$keep"
  echo "FINDING	$msg	$keep" >"$RESULTS/$i"
}

# One worker: allocate its temp files once, then run a contiguous range of module
# indices through [diff_one], reusing those files. Batching the range into a
# single shell (rather than [xargs -I{}] execing a fresh [bash] and five [mktemp]
# per module) removes most of the per-module process-spawn overhead — the oracle
# is spawn/latency-bound, not CPU-bound.
diff_worker() {
  local first="$1" last="$2" i
  local seed mod wax bin ERRLOG
  seed="$(mktemp)"; mod="$(mktemp --suffix=.wasm)"
  wax="$(mktemp --suffix=.wax)"; bin="$(mktemp --suffix=.wasm)"
  ERRLOG="$(mktemp)"   # classify_wax writes the diagnostic here
  trap 'rm -f "$seed" "$mod" "$wax" "$bin" "$ERRLOG"' RETURN
  for ((i = first; i <= last; i++)); do diff_one "$i"; done
}

rm -f "$KEEP"/*.wasm 2>/dev/null
# Fan [COUNT] modules across [JOBS] background workers as contiguous ranges. Each
# worker is a forked subshell of this script, so it inherits the functions and
# variables directly — no [export]/[xargs] round-trip.
chunk=$(((COUNT + JOBS - 1) / JOBS))
for ((w = 0; w < JOBS; w++)); do
  first=$((w * chunk + 1))
  [ "$first" -gt "$COUNT" ] && break
  last=$((first + chunk - 1))
  [ "$last" -gt "$COUNT" ] && last="$COUNT"
  diff_worker "$first" "$last" &
done
wait
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
