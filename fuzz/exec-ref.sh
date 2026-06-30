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
# MODE: codec (wasm->wasm, default) or wax (wasm->wax->wasm).
# REF:  path to the reference interpreter (default ~/sources/Wasm/interpreter/wasm).
# With no arguments, runs the whole core suite. Exits non-zero on any regression.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
REF="${REF:-$HOME/sources/Wasm/interpreter/wasm}"
REWRITE="$(dirname "${BASH_SOURCE[0]}")/wast-rewrite.js"
export MODE="${MODE:-codec}" WAX WASM_TOOLS

wasts=("$@")
if [ ${#wasts[@]} -eq 0 ]; then
  mapfile -t wasts < <(find "$ROOT/test/wasm-test-suite/core" -name '*.wast' | sort)
fi

tested=0 skipped=0 regressions=0 norecompile=0
report="$(mktemp)"

for wast in "${wasts[@]}"; do
  # Baseline: can the reference interpreter run this file at all?
  if ! "$REF" "$wast" >/dev/null 2>&1; then skipped=$((skipped+1)); continue; fi
  tested=$((tested+1))
  rw="$(mktemp --suffix=.wast)"
  # wast-rewrite reports "recompiled=N failed=M" on stderr; M modules wax could
  # not recompile are kept as the original (so NOT tested via wax).
  stats="$(node "$REWRITE" "$wast" 2>&1 >"$rw")"
  norecompile=$((norecompile + $(echo "$stats" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')))
  if ! err="$("$REF" "$rw" 2>&1)"; then
    regressions=$((regressions+1))
    { echo "### $(basename "$wast")"; echo "$err" | head -4; } >>"$report"
  fi
  rm -f "$rw"
done

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
