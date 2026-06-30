#!/usr/bin/env bash
#
# exec-interp.sh [wast-file ...]
#
# Execution (behavioural-equivalence) oracle using wabt's reference interpreter,
# which — unlike the Node runner (fuzz/exec.sh) — fully supports SIMD/v128, GC,
# memory64, etc. with no JS-boundary limitations. For each spec .wast file:
#   1. split it with wast2json into per-module .wasm + a JSON of assertions;
#   2. run spectest-interp on the ORIGINAL modules (baseline);
#   3. recompile each module through wax and run spectest-interp again;
#   4. report assertions that the wax run fails but the baseline passes — those
#      are wax miscompilations (a baseline failure means wabt itself can't run
#      that module's proposal, so it is excluded by the diff).
#
# MODE: codec (wasm->wasm, default) or wax (wasm->wax->wasm).
# With no arguments, runs the whole core suite. Exits non-zero on any regression.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
MODE="${MODE:-codec}"
INTERP="${INTERP:-spectest-interp}"
WAST2JSON="${WAST2JSON:-wast2json}"
FEATURES="--enable-exceptions --enable-threads --enable-function-references \
  --enable-tail-call --enable-gc --enable-memory64 --enable-multi-memory \
  --enable-extended-const --enable-relaxed-simd"

wasts=("$@")
if [ ${#wasts[@]} -eq 0 ]; then
  mapfile -t wasts < <(find "$ROOT/test/wasm-test-suite/core" -name '*.wast' | sort)
fi

recompile() {
  local f="$1" tmp="$1.tmp"
  case "$MODE" in
    codec) timeout "$TIMEOUT" "$WAX" -i wasm -f wasm "$f" -o "$tmp" 2>/dev/null && mv "$tmp" "$f" && return 0 ;;
    wax) timeout "$TIMEOUT" "$WAX" -i wasm -f wax "$f" -o "$f.wax" 2>/dev/null \
         && timeout "$TIMEOUT" "$WAX" -i wax -f wasm "$f.wax" -o "$tmp" 2>/dev/null \
         && mv "$tmp" "$f" && return 0 ;;
  esac
  rm -f "$tmp" "$f.wax"; return 1
}

# The set of "LINE: kind" assertion failures spectest-interp reports for a json.
failures() {
  "$INTERP" $FEATURES "$1" 2>&1 \
    | grep -oE ':[0-9]+: assert_[a-z_]+ (failed|mismatch)' | sort -u
}

nfiles=0 total_reg=0 total_norec=0
report="$(mktemp)"

for wast in "${wasts[@]}"; do
  work="$(mktemp -d)"
  if ! "$WAST2JSON" "$wast" -o "$work/test.json" >/dev/null 2>&1; then
    rm -rf "$work"; continue
  fi
  nfiles=$((nfiles+1))
  base="$(failures "$work/test.json")"   # baseline failures (wabt's own gaps)
  # Recompile the modules an assertion can reach.
  norec=0
  while IFS= read -r f; do
    [ -n "$f" ] && [ -e "$work/$f" ] || continue
    recompile "$work/$f" || norec=$((norec+1))
  done < <(jq -r '.commands[] | select(.type=="module") | .filename' "$work/test.json")
  total_norec=$((total_norec+norec))
  waxf="$(failures "$work/test.json")"    # failures after recompiling through wax
  # Regressions: failing now but not in the baseline.
  regs="$(comm -13 <(printf '%s\n' "$base") <(printf '%s\n' "$waxf"))"
  if [ -n "$regs" ]; then
    n=$(printf '%s\n' "$regs" | grep -c .)
    total_reg=$((total_reg+n))
    printf '%s\n' "$regs" | sed "s#^#$(basename "$wast")#" >>"$report"
  fi
  rm -rf "$work"
done

echo "============= execution oracle via spectest-interp ($MODE) ============="
echo "wast files:             $nfiles"
echo "wax regressions:        $total_reg (assertions the wax build fails but the original passes)"
echo "modules wax could not recompile: $total_norec"
if [ "$total_reg" -gt 0 ]; then
  echo; echo "regressions:"; sort -u "$report" | sed 's/^/  /' | head -60
  echo; echo "full list: $report"
fi
[ "$total_reg" -gt 0 ] && exit 1
exit 0
