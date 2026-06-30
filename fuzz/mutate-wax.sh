#!/usr/bin/env bash
#
# mutate-wax.sh [count]
#
# AST mutation fuzzer for the Wax *source* side. Each iteration takes a random
# valid .wax seed (from wax-corpus.sh) and applies 1-3 AST mutations with the
# fuzz_mutate tool (parse -> mutate one node -> reprint), then runs every oracle
# on the result. Because each mutant is printed from a real AST it always
# re-parses, so — unlike token-level mutation — most mutants reach the type
# checker, the wax->wasm compiler and the round-trip. The mutant's validity is
# unknown, so we hunt for what must never happen on ANY input:
#   * a CRASH (uncaught exception / signal / timeout) in the parser/typer; and
#   * wax accepting a mutant but emitting wasm wasm-tools rejects (FALSE_ACCEPT),
#     or a broken wax->wasm->wax->wasm round-trip.
#
# Seeds come from fuzz/corpus-wax/valid (run fuzz/wax-corpus.sh first).
# Parallel across cores (override with JOBS, oversubscribed like smith.sh since
# the oracle is latency-bound). Failing mutants are saved under the printed dir.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COUNT="${1:-2000}"
SEEDS="${SEEDS:-$ROOT/fuzz/corpus-wax/valid}"
JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
KEEP="$ROOT/fuzz/mutate-findings"
ORACLE="$(dirname "${BASH_SOURCE[0]}")/oracle.sh"
MUT="${MUT:-$ROOT/_build/default/src/bin/fuzz_mutate.exe}"
[ -x "$MUT" ] || { echo "fuzz_mutate not built — run 'dune build' first" >&2; exit 2; }
[ -d "$SEEDS" ] && [ -n "$(find "$SEEDS" -name '*.wax' -print -quit)" ] \
  || { echo "no wax seeds at $SEEDS — run fuzz/wax-corpus.sh first" >&2; exit 2; }
mkdir -p "$KEEP"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT

mapfile -t SEED_FILES < <(find "$SEEDS" -name '*.wax')
NSEEDS=${#SEED_FILES[@]}
printf '%s\n' "${SEED_FILES[@]}" >"$RESULTS/seeds"

# Worker: build mutant #i by applying 1-3 AST mutations to a seed (seed index
# derived from i so workers need no shared RNG), then run the oracle. fuzz_mutate
# applies one mutation per call and always emits parseable wax, so chaining its
# output drives several mutations deep. Findings go to a private file under
# $RESULTS with the temp path rewritten to a preserved copy.
mutate_one() {
  local i="$1" cur nxt out n
  cur="$(mktemp --suffix=.wax)"
  cp "${SEED_FILES[$(( (i * 2654435761) % NSEEDS ))]}" "$cur"
  n=$(( (i % 3) + 1 ))
  while [ "$n" -gt 0 ]; do
    nxt="$(mktemp --suffix=.wax)"
    if "$MUT" "$cur" "$RANDOM" >"$nxt" 2>/dev/null && [ -s "$nxt" ]; then
      mv "$nxt" "$cur"
    else
      rm -f "$nxt"   # a mutation failed; keep the previous mutant
    fi
    n=$((n-1))
  done
  out="$(bash "$ORACLE" "$cur" unknown 2>/dev/null)"
  # Re-verify before reporting: wax is deterministic, so a real finding
  # reproduces, but a transient failure (a wax invocation killed/erroring under
  # heavy parallel load) does not — this keeps the report free of load noise.
  if [ -n "$out" ] && [ -n "$(bash "$ORACLE" "$cur" unknown 2>/dev/null)" ]; then
    local keep="$KEEP/mutant-$i.wax"
    cp "$cur" "$keep"
    echo "${out//$cur/$keep}" >"$RESULTS/$i"
    printf 'F' >&2
  else
    printf '.' >&2
  fi
  rm -f "$cur"
}
export -f mutate_one
export WAX WASM_TOOLS TIMEOUT WT_FEATURES ORACLE RESULTS KEEP NSEEDS MUT
# The seed list is passed via a file ($RESULTS/seeds, written above), not the
# environment: exporting thousands of paths overflows ARG_MAX and every exec in
# the workers fails with E2BIG. Each worker rebuilds the array from that file.
echo "mutating $COUNT variants from $NSEEDS seeds across $JOBS jobs..." >&2
seq 1 "$COUNT" | xargs -P "$JOBS" -I{} bash -c '
  mapfile -t SEED_FILES < "$RESULTS/seeds"; mutate_one "$@"' _ {}
echo >&2

REPORT="$(mktemp)"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
echo "=================== wax mutation report ==================="
echo "mutants checked: $COUNT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null || true)
echo "findings: ${n:-0}"
if [ "${n:-0}" -gt 0 ]; then
  echo
  cut -f2,3 "$REPORT" | sort | uniq -c | sort -rn | sed 's/^/  /'
  echo
  echo "failing mutants saved under $KEEP/ — replay with:"
  echo "  bash fuzz/oracle.sh $KEEP/mutant-<n>.wax unknown"
  echo
  echo "full report with reproduction commands: $REPORT"
fi
grep -q $'\tHIGH\t' "$REPORT" && exit 1
exit 0
