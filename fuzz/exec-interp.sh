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
# Files are processed in parallel across cores (override with JOBS); each runs in
# its own process and temp dir, so a crash or hang on one is contained. A second
# pool (INNER_JOBS) fans out the per-module recompile within a file: a few files
# (const.wast, …) hold thousands of tiny modules and, recompiled serially, pin a
# single core for the whole run. The two pools compound when several module-heavy
# files coincide (transient load up to JOBS*INNER_JOBS short-lived wax
# processes); set INNER_JOBS=1 to disable on a constrained box.
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
INNER_JOBS="${INNER_JOBS:-$JOBS}"

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
export -f recompile

# The set of "LINE: kind" assertion failures spectest-interp reports for a json.
# On the wax path, drop assert_unlinkable: wax may soundly narrow an exported
# immutable global (a const declared at a supertype) to its initializer's type,
# making a previously-incompatible import link — the round-trip contract does not
# promise an unlinkable composition stays unlinkable. The codec path preserves
# types exactly, so it keeps assert_unlinkable strict (a flip there is a real bug).
failures() {
  "$INTERP" $FEATURES "$1" 2>&1 \
    | grep -oE ':[0-9]+: assert_[a-z_]+ (failed|mismatch)' \
    | { if [ "$MODE" = wax ]; then grep -v assert_unlinkable; else cat; fi; } \
    | sort -u
}
export -f failures

RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT

# Worker: process one .wast and write its tallies to a private file under
# $RESULTS — a [SUM <files> <regressions> <norecompile>] line plus one [REG …]
# line per regression — so parallel workers never race on a shared report.
process_wast() {
  local wast="$1" work base waxf regs res norec=0 nreg=0
  work="$(mktemp -d)"
  if ! "$WAST2JSON" "$wast" -o "$work/test.json" >/dev/null 2>&1; then
    rm -rf "$work"; printf 's' >&2; return 0
  fi
  base="$(failures "$work/test.json")"   # baseline failures (wabt's own gaps)
  # Recompile the modules an assertion can reach, fanned out (see INNER_JOBS):
  # const.wast & co. hold thousands of modules that would otherwise be serial.
  norec=$(jq -r '.commands[] | select(.type=="module") | .filename' "$work/test.json" \
    | while IFS= read -r f; do
        [ -n "$f" ] && [ -e "$work/$f" ] && printf '%s\0' "$work/$f"
      done \
    | xargs -0 -r -P "$INNER_JOBS" -I{} bash -c 'recompile "$1" || echo X' _ {} \
    | grep -c X)
  waxf="$(failures "$work/test.json")"    # failures after recompiling through wax
  # Regressions: failing now but not in the baseline.
  regs="$(comm -13 <(printf '%s\n' "$base") <(printf '%s\n' "$waxf"))"
  res="$(mktemp -p "$RESULTS")"
  if [ -n "$regs" ]; then
    nreg=$(printf '%s\n' "$regs" | grep -c .)
    printf '%s\n' "$regs" | sed "s#^#REG $(basename "$wast")#" >>"$res"
  fi
  echo "SUM 1 $nreg $norec" >>"$res"
  rm -rf "$work"; printf '.' >&2
}
export -f process_wast
export WAX WASM_TOOLS TIMEOUT MODE INTERP WAST2JSON FEATURES RESULTS INNER_JOBS

printf '%s\0' "${wasts[@]}" | xargs -0 -P "$JOBS" -I{} bash -c 'process_wast "$@"' _ {}
echo >&2

nfiles=0 total_reg=0 total_norec=0
report="$(mktemp)"
allres="$(cat "$RESULTS"/* 2>/dev/null)"
grep '^REG ' <<<"$allres" | sed 's/^REG //' >"$report"
while read -r _ files nreg norec; do
  nfiles=$((nfiles+files)); total_reg=$((total_reg+nreg)); total_norec=$((total_norec+norec))
done < <(grep '^SUM ' <<<"$allres")

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
