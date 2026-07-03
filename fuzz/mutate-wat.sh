#!/usr/bin/env bash
#
# mutate-wat.sh [count]
#
# Text-mutation fuzzer for the WAT *input* path (the lexer and parser, which the
# wax-side fuzzer never exercises — it only feeds Wax, and the corpus/smith
# oracles only feed *valid* wasm/wat). Each iteration takes a random valid .wat
# seed (from wat-corpus.sh) and applies 1-3 text mutations with mutate-wat.awk —
# chiefly injecting out-of-range / edge-value numeric literals and over-long
# string escapes into the positions the lexer/parser convert — then runs the
# oracle. The mutant is almost always invalid, so a clean rejection (exit 123 /
# 128) is expected and NOT a finding; we hunt for what must never happen on ANY
# input: a CRASH (uncaught exception / signal / timeout) while parsing/converting.
#
# Seeds come from fuzz/corpus-wat/valid (run fuzz/wat-corpus.sh first).
# Parallel across cores (override with JOBS, oversubscribed like smith.sh since
# the oracle is latency-bound). Failing mutants are saved under the printed dir.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COUNT="${1:-2000}"
SEEDS="${SEEDS:-$ROOT/fuzz/corpus-wat/valid}"
JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
KEEP="$ROOT/fuzz/mutate-wat-findings"
ORACLE="$(dirname "${BASH_SOURCE[0]}")/oracle.sh"
AWK="$(dirname "${BASH_SOURCE[0]}")/mutate-wat.awk"
[ -d "$SEEDS" ] && [ -n "$(find "$SEEDS" -name '*.wat' -print -quit)" ] \
  || { echo "no wat seeds at $SEEDS — run fuzz/wat-corpus.sh first" >&2; exit 2; }
mkdir -p "$KEEP"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"  # run against a snapshot so a concurrent rebuild can't corrupt workers

mapfile -t SEED_FILES < <(find "$SEEDS" -name '*.wat' | sort)
NSEEDS=${#SEED_FILES[@]}
printf '%s\n' "${SEED_FILES[@]}" >"$RESULTS/seeds"

# Worker: build mutant #i by applying 1-3 text mutations to a seed (index from i),
# then run the oracle, re-verifying any finding (wax is deterministic, so a
# transient load failure does not reproduce).
mutate_one() {
  local i="$1" cur nxt out n step=0
  cur="$(mktemp --suffix=.wat)"
  cp "${SEED_FILES[$(( (i * 2654435761) % NSEEDS ))]}" "$cur"
  n=$(( (i % 3) + 1 ))
  while [ "$n" -gt 0 ]; do
    nxt="$(mktemp --suffix=.wat)"
    # Deterministic per-(mutant, step) seed from the master $SEED so the campaign
    # replays from one number (was $RANDOM — irreproducible).
    if awk -v seed="$(( SEED + i * 8 + step ))" -f "$AWK" "$cur" >"$nxt" 2>/dev/null && [ -s "$nxt" ]; then
      mv "$nxt" "$cur"
    else
      rm -f "$nxt"
    fi
    step=$((step + 1)); n=$((n - 1))
  done
  out="$(bash "$ORACLE" "$cur" unknown 2>/dev/null)"
  if [ -n "$out" ] && [ -n "$(bash "$ORACLE" "$cur" unknown 2>/dev/null)" ]; then
    local keep="$KEEP/mutant-$i.wat"
    cp "$cur" "$keep"
    echo "${out//$cur/$keep}" >"$RESULTS/$i"
    printf 'F' >&2
  else
    printf '.' >&2
  fi
  rm -f "$cur"
}
export -f mutate_one
export WAX WASM_TOOLS TIMEOUT WT_FEATURES ORACLE RESULTS KEEP NSEEDS AWK SEED

announce_seed "$(basename "$0") $COUNT"
echo "mutating $COUNT WAT variants from $NSEEDS seeds across $JOBS jobs..." >&2
seq 1 "$COUNT" | xargs -P "$JOBS" -I{} bash -c '
  mapfile -t SEED_FILES < "$RESULTS/seeds"; mutate_one "$@"' _ {}
echo >&2

REPORT="$(mktemp)"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
echo "=================== wat mutation report ==================="
echo "mutants checked: $COUNT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null || true)
echo "findings: ${n:-0}"
if [ "${n:-0}" -gt 0 ]; then
  echo
  cut -f2,3 "$REPORT" | sort | uniq -c | sort -rn | sed 's/^/  /'
  echo
  echo "failing mutants saved under $KEEP/ — replay with:"
  echo "  bash fuzz/oracle.sh $KEEP/mutant-<n>.wat unknown"
  echo
  echo "full report with reproduction commands: $REPORT"
fi
grep -q $'\tHIGH\t' "$REPORT" && exit 1
exit 0
