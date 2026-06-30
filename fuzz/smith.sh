#!/usr/bin/env bash
#
# smith.sh [count] [bytes]
#
# Generate `count` (default 200) guaranteed-valid wasm modules with
# `wasm-tools smith` and run every oracle on each. smith turns random bytes
# into a valid module, so it explores corners no hand-written corpus reaches —
# and because the module is valid by construction, EXPECT=valid: any rejection,
# crash, invalid emission, or broken round-trip is a real wax bug.
#
# `bytes` (default 2048) is how many random bytes seed each module; larger means
# bigger, more complex modules.
#
# Modules are generated and checked in parallel across cores (override with
# JOBS); the oracle is the bottleneck (~a dozen wax invocations per module), so
# fanning out keeps every core busy rather than one. Each runs in its own
# process, so a crash or hang on one input is contained, not fatal to the run.
#
# Determinism: there is no Math.random() here — each module is seeded from
# /dev/urandom. Re-running explores fresh modules. A failing module's .wasm is
# preserved under the printed directory so it can be replayed with oracle.sh.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COUNT="${1:-200}"
BYTES="${2:-2048}"
# The per-module oracle is latency-bound — a dozen short-lived wax forks, each
# mostly fork/exec/IO wait — so the cores sit idle at one worker apiece.
# Oversubscribing fills that idle time; ~4x the core count is the sweet spot
# here (throughput plateaus around 6x). Raise JOBS further on a roomy machine.
JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
KEEP="$ROOT/fuzz/smith-findings"
mkdir -p "$KEEP"
REPORT="$(mktemp)"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
ORACLE="$(dirname "${BASH_SOURCE[0]}")/oracle.sh"

# SMITH_FLAGS (the smith proposal set, threads disabled) comes from lib.sh, shared
# with wax-corpus.sh. Passed to the worker as a string (no flag value contains a
# space) so it survives `xargs`.

# Worker: generate module #i from fresh random bytes and run every oracle on it.
# A finding is written to its own file under $RESULTS (no concurrent writes to a
# shared report) with the temp path rewritten to the preserved copy; progress is
# a single byte to stderr (. checked, F finding, s smith could not generate).
smith_one() {
  local i="$1" seed mod out
  seed="$(mktemp)"; mod="$(mktemp --suffix=.wasm)"
  head -c "$SMITH_BYTES" /dev/urandom >"$seed"
  if ! "$WASM_TOOLS" smith $SMITH_FLAGS "$seed" -o "$mod" 2>/dev/null; then
    rm -f "$seed" "$mod"; printf 's' >&2; return 0
  fi
  out="$(bash "$ORACLE" "$mod" valid)"
  if [ -n "$out" ]; then
    local keep="$SMITH_KEEP/smith-$i.wasm"
    cp "$mod" "$keep"
    echo "${out//$mod/$keep}" >"$RESULTS/$i"
    printf 'F' >&2
  else
    printf '.' >&2
  fi
  rm -f "$seed" "$mod"
}
export -f smith_one
export WAX WASM_TOOLS TIMEOUT WT_FEATURES ORACLE RESULTS
export SMITH_FLAGS SMITH_BYTES="$BYTES" SMITH_KEEP="$KEEP"

echo "generating + checking $COUNT modules ($BYTES seed bytes each) across $JOBS jobs..." >&2
seq 1 "$COUNT" | xargs -P "$JOBS" -I{} bash -c 'smith_one "$@"' _ {}
echo >&2
cat "$RESULTS"/* 2>/dev/null >"$REPORT"

echo "=================== smith report ==================="
echo "modules checked: $COUNT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null || echo 0)
echo "findings: $n"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3 "$REPORT" | sort | uniq -c | sort -rn | sed 's/^/  /'
  echo
  echo "failing modules saved under $KEEP/ — replay with:"
  echo "  bash fuzz/oracle.sh $KEEP/smith-<n>.wasm valid"
  echo
  echo "full report with reproduction commands: $REPORT"
fi
grep -q $'\tHIGH\t' "$REPORT" && exit 1
exit 0
