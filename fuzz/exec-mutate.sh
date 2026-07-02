#!/usr/bin/env bash
#
# exec-mutate.sh [wast-file ...]
#
# Behavioural-equivalence oracle on *mutated* spec modules. The plain execution
# oracles (exec-ref.sh) can only check behaviour where spec assertions exist —
# the fixed .wast suite. This lifts that ceiling: `wasm-tools mutate
# --preserve-semantics` rewrites each module into a structurally novel but
# behaviourally identical one, so the script's own assertions still hold, giving
# an endless supply of assertion-bearing modules to run wax against.
#
# Per .wast (all driven by the reference interpreter, REF):
#   1. baseline the ORIGINAL — skip the file if REF cannot run it (a proposal it
#      lacks, e.g. stack switching);
#   2. replace each module with a semantics-preserving mutant (MODE=mutate) and
#      baseline THAT — if it fails, the mutation did not preserve behaviour (a
#      wasm-mutate limitation, or a mutant the interpreter mishandles), so the
#      file is not wax's fault: counted "mut-broke", not a regression;
#   3. take the SAME mutant but wax-recompiled (MODE=wax; the identical per-module
#      seed makes it the exact module step 2 baselined) and run it — passing the
#      original baseline yet failing here is a wax MISCOMPILATION on a module the
#      fixed suite never contained.
#
# Deterministic per file (seed = master SEED + a hash of the path). Parallel
# across cores. Exits non-zero on any regression, so it can gate CI.
#
# Env: REF (reference interpreter), SEED (master), MUTATE_STEPS (mutations per
# module, default in wast-rewrite.js), plus WAX / WASM_TOOLS from lib.sh.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
REF="${REF:-$HOME/sources/Wasm/interpreter/wasm}"
REWRITE="$(dirname "${BASH_SOURCE[0]}")/wast-rewrite.js"
NODE="${NODE:-node}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
[ -x "$REF" ] || { echo "reference interpreter not found at $REF (set REF)" >&2; exit 2; }
command -v "$NODE" >/dev/null 2>&1 || { echo "node not found (set NODE)" >&2; exit 2; }

wasts=("$@")
if [ ${#wasts[@]} -eq 0 ]; then
  mapfile -t wasts < <(find "$ROOT/test/wasm-test-suite/core" -name '*.wast' | sort)
fi

RESULTS="$(mktemp -d)"   # one "SUM tested skipped regressions mutbroke norecompile" line per worker
REPORTS="$(mktemp -d)"   # one regression block per regressing file
trap 'rm -rf "$RESULTS" "$REPORTS"' EXIT
export REF REWRITE NODE RESULTS REPORTS WAX WASM_TOOLS SEED

# Worker: mutate one .wast, verify the mutant baselines, then check wax on it.
process_wast() {
  local wast="$1" mut waxed err nf reg=0
  # 1. baseline the original
  if ! "$REF" "$wast" >/dev/null 2>&1; then
    echo "SUM 0 1 0 0 0" >"$(mktemp -p "$RESULTS")"; printf 'k' >&2; return 0
  fi
  # Per-file deterministic seed: master SEED mixed with a hash of the path.
  local sd=$(( (SEED + $(cksum <<<"$wast" | cut -d' ' -f1)) % 2000000000 ))
  # 2. semantics-preserving mutant; it must still satisfy the assertions.
  mut="$(mktemp --suffix=.wast)"
  MODE=mutate MUTATE_SEED="$sd" "$NODE" "$REWRITE" "$wast" 2>/dev/null >"$mut"
  if ! "$REF" "$mut" >/dev/null 2>&1; then
    echo "SUM 0 0 0 1 0" >"$(mktemp -p "$RESULTS")"; rm -f "$mut"; printf 'm' >&2; return 0
  fi
  # 3. the same mutant, wax-recompiled.
  waxed="$(mktemp --suffix=.wast)"
  nf="$(MODE=wax MUTATE_SEED="$sd" "$NODE" "$REWRITE" "$wast" 2>&1 >"$waxed" \
        | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"; nf="${nf:-0}"
  if ! err="$("$REF" "$waxed" 2>&1)"; then
    reg=1
    { echo "### $(basename "$wast")  (seed $sd)"; echo "$err" | head -4; } >"$(mktemp -p "$REPORTS")"
  fi
  echo "SUM 1 0 $reg 0 $nf" >"$(mktemp -p "$RESULTS")"
  rm -f "$mut" "$waxed"; printf '.' >&2
}
export -f process_wast

announce_seed "$(basename "$0")"
echo "mutate+run ${#wasts[@]} .wast files across $JOBS jobs..." >&2
printf '%s\0' "${wasts[@]}" | xargs -0 -P "$JOBS" -I{} bash -c 'process_wast "$@"' _ {}
echo >&2

tested=0 skipped=0 regressions=0 mutbroke=0 norecompile=0
while read -r _ t s r mb n; do
  tested=$((tested + t)); skipped=$((skipped + s)); regressions=$((regressions + r))
  mutbroke=$((mutbroke + mb)); norecompile=$((norecompile + n))
done < <(cat "$RESULTS"/* 2>/dev/null)
report="$(mktemp)"; cat "$REPORTS"/* 2>/dev/null >"$report"

echo "========= execution oracle on semantics-preserving mutants ========="
echo "files tested:      $tested"
echo "files skipped:     $skipped (reference interpreter cannot run the original)"
echo "mutation not preserving (skipped, not wax): $mutbroke"
echo "modules wax could not recompile: $norecompile (kept as original — not tested via wax)"
echo "wax regressions:   $regressions (mutant baselined, then failed after wax recompiled it)"
if [ "$regressions" -gt 0 ]; then
  echo; echo "regressions:"; sed 's/^/  /' "$report" | head -80
  echo; echo "full list: $report"
fi
[ "$regressions" -gt 0 ] && exit 1
exit 0
