#!/usr/bin/env bash
#
# run.sh [corpus-dir]
#
# Drive oracle.sh over an entire corpus and summarise. Files under a directory
# named "valid" are run with EXPECT=valid, under "invalid" with EXPECT=invalid,
# everything else as unknown. Each file runs in its own process, so a segfault
# or hang on one input is contained and reported, not fatal to the run.
#
# Exits non-zero if any HIGH-severity finding was reported, so it can gate CI.
# Files run in parallel across cores (override with JOBS); each runs in its own
# process, so a crash or hang on one input is contained, not fatal to the run.
#
# Scope: this drives the *validity/crash/round-trip* oracles (oracle.sh) over a
# static corpus. It does NOT run the behavioural-equivalence (execution) oracles
# — those need a runner and spec .wast assertions; run them separately with
# fuzz/exec-ref.sh (preferred), fuzz/exec-interp.sh, or fuzz/exec.sh.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CORPUS="${1:-$ROOT/fuzz/corpus}"
[ -d "$CORPUS" ] || { echo "no corpus at $CORPUS — run fuzz/build-corpus.sh first" >&2; exit 2; }

# The oracle is latency-bound (a handful of short-lived wax forks per file), so
# one worker per core leaves the cores mostly idle. Oversubscribe (like smith.sh);
# ~4x the core count is the sweet spot.
JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
REPORT="$(mktemp)"
ORACLE="$(dirname "${BASH_SOURCE[0]}")/oracle.sh"

# Worker: derive the expected validity from the path, then run the oracle.
check_one() {
  case "$1" in
    */valid/*)   expect=valid ;;
    */invalid/*) expect=invalid ;;
    *)           expect=unknown ;;
  esac
  bash "$2" "$1" "$expect"
}
export -f check_one

total=$(find "$CORPUS" -type f \( -name '*.wat' -o -name '*.wasm' -o -name '*.wax' \) | wc -l)
echo "checking $total files across $JOBS jobs..." >&2
find "$CORPUS" -type f \( -name '*.wat' -o -name '*.wasm' -o -name '*.wax' \) -print0 \
  | sort -z \
  | WAX="$WAX" WASM_TOOLS="$WASM_TOOLS" TIMEOUT="$TIMEOUT" WT_FEATURES="$WT_FEATURES" \
    xargs -0 -P "$JOBS" -I{} bash -c 'check_one "$@"' _ {} "$ORACLE" >"$REPORT"

echo "=================== fuzz report ==================="
echo "corpus:   $CORPUS"
echo "checked:  $total files"
nfind=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); nfind=${nfind:-0}
echo "findings: $nfind"
echo
if [ "$nfind" -gt 0 ]; then
  echo "by category / severity:"
  cut -f2,3 "$REPORT" | sort | uniq -c | sort -rn | sed 's/^/  /'
  echo
  echo "details (CATEGORY  SEVERITY  INPUT  DETAIL):"
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
  echo
  echo "full report with reproduction commands: $REPORT"
fi
echo
echo "note: behavioural (execution) oracles are separate — run fuzz/exec-ref.sh"

# Gate on HIGH findings only (REVIEW items may include benign naming noise).
grep -q $'\tHIGH\t' "$REPORT" && exit 1
exit 0
