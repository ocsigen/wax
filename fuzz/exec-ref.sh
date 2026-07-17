#!/usr/bin/env bash
#
# exec-ref.sh [wast-file ...]
#
# Execution (behavioural-equivalence) oracle driven by the WebAssembly *reference
# interpreter*, which runs .wast scripts directly with full support for the
# merged proposals (GC, SIMD, exceptions, multi-memory, ...) — far more than
# wabt's wast2json (which crashes on ~100 core files) or Node (no v128). For each
# .wast:
#   1. run the reference interpreter on the original (baseline);
#   2. rewrite it, replacing each text module with wax's recompiled binary
#      (fuzz/wast-rewrite.js), and run the reference interpreter again.
# A file whose baseline already fails (e.g. the stack-switching proposal, which
# this interpreter does not implement) is skipped. A file that passes the
# baseline but fails after wax recompiled its modules is a wax miscompilation.
#
# MODE: codec (wasm->wasm, default), wax (wasm->wax->wasm), or wax-text
#       (wat->wax->wasm, feeding each module's TEXT to wax — the input pipeline a
#       wasm binary cannot exercise: it drives from_wasm's WAT reader, so
#       text-only miscompiles like symbolic-vs-numeric references and
#       unsanitizable identifiers become behaviourally observable).
# HOSTILE_SEED: with MODE=wax-text, rename one identifier per module to a
#       Wax-hostile spelling (unsanitizable / fallback-colliding / keyword)
#       before wax sees it — semantics-preserving, so the assertions still hold
#       unless wax's name hygiene miscompiles (e.g. a colliding label retargets a
#       branch).
# REF:  path to the reference interpreter (default ~/sources/Wasm/interpreter/wasm).
# With no arguments, runs the whole core suite. Exits non-zero on any regression.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
REF="${REF:-$HOME/sources/Wasm/interpreter/wasm}"
# Without REF every file's baseline "fails" and is skipped, so the oracle would
# report clean while testing nothing. Skip loudly instead.
[ -x "$REF" ] || { echo "reference interpreter not found at $REF (set REF)" >&2; exit 2; }
REWRITE="$(dirname "${BASH_SOURCE[0]}")/wast-rewrite.js"
export MODE="${MODE:-codec}" WAX WASM_TOOLS
# Files are processed in parallel across cores (override with JOBS); each runs in
# its own process and temp dir, so a crash or hang on one is contained.
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

wasts=("$@")
if [ ${#wasts[@]} -eq 0 ]; then
  mapfile -t wasts < <(find "$ROOT/test/wasm-test-suite/core" -name '*.wast' | sort)
fi

RESULTS="$(mktemp -d)"   # one [SUM tested skipped regressions norecompile] line per worker
REPORTS="$(mktemp -d)"   # one free-form regression block per regressing file
trap 'rm -rf "$RESULTS" "$REPORTS"' EXIT

# Worker: differentially run one .wast through the reference interpreter and
# write its tallies to a private file under $RESULTS (and any regression block to
# $REPORTS), so parallel workers never race on a shared report.
process_wast() {
  local wast="$1" rw stats nf reg=0 err
  # Baseline: can the reference interpreter run this file at all?
  if ! "$REF" "$wast" >/dev/null 2>&1; then
    echo "SUM 0 1 0 0" >"$(mktemp -p "$RESULTS")"; printf 'k' >&2; return 0
  fi
  rw="$(mktemp --suffix=.wast)"
  # wast-rewrite reports "recompiled=N failed=M" on stderr; M modules wax could
  # not recompile are kept as the original (so NOT tested via wax).
  stats="$(node "$REWRITE" "$wast" 2>&1 >"$rw")"
  nf="$(echo "$stats" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"; nf="${nf:-0}"
  if ! err="$("$REF" "$rw" 2>&1)"; then
    reg=1
    { echo "### $(basename "$wast")"; echo "$err" | head -4; } >"$(mktemp -p "$REPORTS")"
  fi
  echo "SUM 1 0 $reg $nf" >"$(mktemp -p "$RESULTS")"
  rm -f "$rw"; printf '.' >&2
}
export -f process_wast
export REF REWRITE RESULTS REPORTS

printf '%s\0' "${wasts[@]}" | xargs -0 -P "$JOBS" -I{} bash -c 'process_wast "$@"' _ {}
echo >&2

tested=0 skipped=0 regressions=0 norecompile=0
while read -r _ t s r n; do
  tested=$((tested+t)); skipped=$((skipped+s))
  regressions=$((regressions+r)); norecompile=$((norecompile+n))
done < <(cat "$RESULTS"/* 2>/dev/null)
report="$(mktemp)"
cat "$REPORTS"/* 2>/dev/null >"$report"

echo "============= execution oracle via reference interpreter ($MODE) ============="
echo "files tested:    $tested"
echo "files skipped:   $skipped (reference interpreter cannot run the original — e.g. stack switching)"
echo "modules wax could not recompile: $norecompile (kept as original — not tested via wax)"
echo "wax regressions: $regressions (passed the baseline, failed after wax recompiled the modules)"
if [ "$regressions" -gt 0 ]; then
  echo; echo "regressions:"; sed 's/^/  /' "$report" | head -80
  echo; echo "full list: $report"
fi
[ "$regressions" -gt 0 ] && exit 1
exit 0
