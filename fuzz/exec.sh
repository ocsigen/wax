#!/usr/bin/env bash
#
# exec.sh [wast-file ...]
#
# Execution (behavioural-equivalence) oracle. For each spec .wast file:
#   1. split it into per-module .wasm files + a JSON of assertions
#      (wasm-tools json-from-wast);
#   2. recompile each module THROUGH wax, replacing the .wasm;
#   3. run the original assert_return / assert_trap assertions against wax's
#      recompiled modules (node fuzz/exec-run.js).
#
# A behavioural mismatch means wax compiled the module to something that runs
# differently — a miscompilation the validity/crash oracles cannot see. Modules
# wax cannot recompile, or that this Node build cannot instantiate (an
# unsupported proposal), are skipped and counted, not failed.
#
# MODE selects what to run (default wax):
#   wax   = wasm -> wax -> wasm  (the full language conversion: from_wasm + to_wasm)
#   codec = wasm -> wasm         (just the binary reader/writer)
#   self  = run the originals against the spec's expected values (validates the
#           harness itself; no wax involved)
#
# With no arguments, runs the whole core suite. Exits non-zero on any mismatch.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
RUNNER="$(dirname "${BASH_SOURCE[0]}")/exec-run.js"
MODE="${MODE:-wax}"
NODE="${NODE:-node}"
# Files are processed in parallel across cores (override with JOBS); each runs in
# its own process and temp dir, so a crash or hang on one is contained. A second
# pool (INNER_JOBS) fans out the per-module recompile within a file: a few files
# (const.wast, …) hold thousands of tiny modules and, recompiled serially, pin a
# single core for the whole run while the rest sit idle. The two pools compound
# when several module-heavy files coincide (transient load up to JOBS*INNER_JOBS
# short-lived wax processes); set INNER_JOBS=1 to disable on a constrained box.
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
INNER_JOBS="${INNER_JOBS:-$JOBS}"

wasts=("$@")
if [ ${#wasts[@]} -eq 0 ]; then
  mapfile -t wasts < <(find "$ROOT/test/wasm-test-suite/core" -name '*.wast' | sort)
fi

# Recompile one module file (in the wax dir, in place) through wax for the chosen
# MODE; returns non-zero (and removes the file) if wax cannot reproduce it.
recompile() {
  local f="$1" tmp="$1.tmp"
  case "$MODE" in
    codec)
      if timeout "$TIMEOUT" "$WAX" -i wasm -f wasm "$f" -o "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"; return 0
      fi ;;
    wax)
      if timeout "$TIMEOUT" "$WAX" -i wasm -f wax "$f" -o "$f.wax" 2>/dev/null \
        && timeout "$TIMEOUT" "$WAX" -i wax -f wasm "$f.wax" -o "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"; return 0
      fi ;;
  esac
  rm -f "$f" "$tmp" "$f.wax"; return 1
}
export -f recompile

RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT

# Worker: process one .wast and write its tallies to a private file under
# $RESULTS — a [SUM <files> <ran> <failed> <skipped> <norecompile> <uninst>]
# line plus one [FAIL …] line per mismatch — so parallel workers never race on a
# shared report. The parent sums the SUM lines and collects the FAIL lines.
process_wast() {
  local wast="$1" work res out norec=0 ran=0 failed=0 skipped=0 wax_uninstantiable=0
  work="$(mktemp -d)"
  if ! "$WASM_TOOLS" json-from-wast "$wast" --wasm-dir "$work" \
        --output "$work/test.json" >/dev/null 2>&1; then
    rm -rf "$work"; printf 's' >&2; return 0
  fi
  if [ "$MODE" = self ]; then
    # Self-check: run the originals against the spec's expected values (validates
    # the harness itself). No recompilation, one directory.
    out="$("$NODE" "$RUNNER" "$work/test.json" "$work" 2>&1)"
  else
    # The original modules stay in [work]; wax's recompiled copies go in
    # [work/wax] so the runner can compare the two behaviours.
    mkdir -p "$work/wax"
    cp "$work"/*.wasm "$work/wax/" 2>/dev/null
    # Recompile only the modules an assertion can reach (the [module] commands);
    # the .wasm files emitted for assert_invalid / assert_malformed carry no
    # assertions, so they are left out of the count. The recompile is itself
    # fanned out: a few files (e.g. const.wast) hold thousands of tiny modules
    # and would otherwise pin a single core for the whole run while the rest sit
    # idle. Each failed recompile prints an X; their count is [norec].
    norec=$(jq -r '.commands[] | select(.type=="module") | .filename' "$work/test.json" \
      | while IFS= read -r f; do
          [ -n "$f" ] && [ -e "$work/wax/$f" ] && printf '%s\0' "$work/wax/$f"
        done \
      | xargs -0 -r -P "$INNER_JOBS" -I{} bash -c 'recompile "$1" || echo X' _ {} \
      | grep -c X)
    # Differentially execute: original vs wax's recompiled modules.
    out="$("$NODE" "$RUNNER" "$work/test.json" "$work" "$work/wax" 2>&1)"
  fi
  res="$(mktemp -p "$RESULTS")"
  while IFS= read -r line; do
    case "$line" in
      FAIL*) echo "FAIL $(basename "$wast"): ${line#FAIL }" >>"$res" ;;
      SUMMARY*) eval "$(echo "$line" | sed 's/SUMMARY //')" ;;
    esac
  done <<<"$out"
  echo "SUM 1 $ran $failed $skipped $norec $wax_uninstantiable" >>"$res"
  rm -rf "$work"; printf '.' >&2
}
export -f process_wast
export WAX WASM_TOOLS TIMEOUT NODE RUNNER MODE RESULTS INNER_JOBS

printf '%s\0' "${wasts[@]}" | xargs -0 -P "$JOBS" -I{} bash -c 'process_wast "$@"' _ {}
echo >&2

total_ran=0 total_failed=0 total_skipped=0 total_norecompile=0 total_uninst=0
nfiles=0
fail_report="$(mktemp)"
allres="$(cat "$RESULTS"/* 2>/dev/null)"
grep '^FAIL ' <<<"$allres" | sed 's/^FAIL //' >"$fail_report"
while read -r _ files ran failed skipped norec uninst; do
  nfiles=$((nfiles+files)); total_ran=$((total_ran+ran))
  total_failed=$((total_failed+failed)); total_skipped=$((total_skipped+skipped))
  total_norecompile=$((total_norecompile+norec)); total_uninst=$((total_uninst+uninst))
done < <(grep '^SUM ' <<<"$allres")

echo "=================== execution oracle ($MODE) ==================="
echo "wast files:             $nfiles"
echo "assertions compared:    $total_ran"
echo "behavioural mismatches: $total_failed"
echo "skipped assertions:     $total_skipped (unsupported value types)"
echo "modules wax could not recompile: $total_norecompile"
echo "modules wax recompiled but Node could not load: $total_uninst"
if [ "$total_failed" -gt 0 ]; then
  echo; echo "mismatches (deduplicated):"
  sort -u "$fail_report" | sed 's/^/  /' | head -60
  echo; echo "full list: $fail_report"
fi
[ "$total_failed" -gt 0 ] && exit 1
exit 0
