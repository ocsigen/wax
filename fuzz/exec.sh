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

total_ran=0 total_failed=0 total_skipped=0 total_norecompile=0 total_uninst=0
nfiles=0
fail_report="$(mktemp)"

for wast in "${wasts[@]}"; do
  work="$(mktemp -d)"
  if ! "$WASM_TOOLS" json-from-wast "$wast" --wasm-dir "$work" \
        --output "$work/test.json" >/dev/null 2>&1; then
    rm -rf "$work"; continue
  fi
  nfiles=$((nfiles+1))
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
    # assertions, so they are left out of the count.
    norec=0
    while IFS= read -r f; do
      [ -n "$f" ] && [ -e "$work/wax/$f" ] || continue
      recompile "$work/wax/$f" || norec=$((norec+1))
    done < <(jq -r '.commands[] | select(.type=="module") | .filename' "$work/test.json")
    total_norecompile=$((total_norecompile+norec))
    # Differentially execute: original vs wax's recompiled modules.
    out="$("$NODE" "$RUNNER" "$work/test.json" "$work" "$work/wax" 2>&1)"
  fi
  while IFS= read -r line; do
    case "$line" in
      FAIL*) echo "$(basename "$wast"): ${line#FAIL }" >>"$fail_report" ;;
      SUMMARY*)
        eval "$(echo "$line" | sed 's/SUMMARY //')"
        total_ran=$((total_ran+ran)); total_failed=$((total_failed+failed))
        total_skipped=$((total_skipped+skipped))
        total_uninst=$((total_uninst+wax_uninstantiable)) ;;
    esac
  done <<<"$out"
  rm -rf "$work"
done

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
