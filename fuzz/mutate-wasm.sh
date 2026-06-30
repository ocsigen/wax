#!/usr/bin/env bash
#
# mutate-wasm.sh [count]
#
# Byte-mutation fuzzer for the wasm-binary *input* path (the binary reader, which
# no other fuzzer exercises on malformed input: smith and the corpus are always
# valid, and mutate-wax/-wat feed text). Each iteration takes a random valid
# .wasm seed and applies 1-3 byte mutations with mutate-wasm.js — flips,
# truncation, LEB-edge bytes, insert/delete — keeping the magic+version header so
# the mutant reaches the section parser, then runs the oracle. The mutant is
# almost always malformed, so a clean rejection (exit 123 / 128) is expected and
# NOT a finding; we hunt for what must never happen on ANY input: a CRASH
# (uncaught exception / signal / timeout) while decoding.
#
# Seeds default to the valid wasm corpus (fuzz/corpus/valid, from
# build-corpus.sh); override with SEEDS. Parallel across cores (override with
# JOBS, oversubscribed like smith.sh since the oracle is latency-bound). Failing
# mutants are saved under the printed dir.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COUNT="${1:-2000}"
SEEDS="${SEEDS:-$ROOT/fuzz/corpus/valid}"
JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
KEEP="$ROOT/fuzz/mutate-wasm-findings"
ORACLE="$(dirname "${BASH_SOURCE[0]}")/oracle.sh"
MUT="$(dirname "${BASH_SOURCE[0]}")/mutate-wasm.js"
NODE="${NODE:-node}"
command -v "$NODE" >/dev/null 2>&1 || { echo "node not found (set NODE)" >&2; exit 2; }
[ -d "$SEEDS" ] && [ -n "$(find "$SEEDS" -name '*.wasm' -print -quit)" ] \
  || { echo "no wasm seeds at $SEEDS — run fuzz/build-corpus.sh first" >&2; exit 2; }
mkdir -p "$KEEP"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT

mapfile -t SEED_FILES < <(find "$SEEDS" -name '*.wasm')
NSEEDS=${#SEED_FILES[@]}
printf '%s\n' "${SEED_FILES[@]}" >"$RESULTS/seeds"

# Worker: build mutant #i by applying 1-3 byte mutations to a seed (index from
# i), then run the oracle, re-verifying any finding (wax is deterministic, so a
# transient load failure does not reproduce).
mutate_one() {
  local i="$1" cur nxt out n
  cur="$(mktemp --suffix=.wasm)"
  cp "${SEED_FILES[$(( (i * 2654435761) % NSEEDS ))]}" "$cur"
  n=$(( (i % 3) + 1 ))
  while [ "$n" -gt 0 ]; do
    nxt="$(mktemp --suffix=.wasm)"
    if "$NODE" "$MUT" "$cur" "$RANDOM" >"$nxt" 2>/dev/null && [ -s "$nxt" ]; then
      mv "$nxt" "$cur"
    else
      rm -f "$nxt"
    fi
    n=$((n-1))
  done
  out="$(bash "$ORACLE" "$cur" unknown 2>/dev/null)"
  if [ -n "$out" ] && [ -n "$(bash "$ORACLE" "$cur" unknown 2>/dev/null)" ]; then
    local keep="$KEEP/mutant-$i.wasm"
    cp "$cur" "$keep"
    echo "${out//$cur/$keep}" >"$RESULTS/$i"
    printf 'F' >&2
  else
    printf '.' >&2
  fi
  rm -f "$cur"
}
export -f mutate_one
export WAX WASM_TOOLS TIMEOUT WT_FEATURES ORACLE RESULTS KEEP NSEEDS MUT NODE

echo "mutating $COUNT wasm variants from $NSEEDS seeds across $JOBS jobs..." >&2
seq 1 "$COUNT" | xargs -P "$JOBS" -I{} bash -c '
  mapfile -t SEED_FILES < "$RESULTS/seeds"; mutate_one "$@"' _ {}
echo >&2

REPORT="$(mktemp)"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
echo "=================== wasm mutation report ==================="
echo "mutants checked: $COUNT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null || true)
echo "findings: ${n:-0}"
if [ "${n:-0}" -gt 0 ]; then
  echo
  cut -f2,3 "$REPORT" | sort | uniq -c | sort -rn | sed 's/^/  /'
  echo
  echo "failing mutants saved under $KEEP/ — replay with:"
  echo "  bash fuzz/oracle.sh $KEEP/mutant-<n>.wasm unknown"
  echo
  echo "full report with reproduction commands: $REPORT"
fi
grep -q $'\tHIGH\t' "$REPORT" && exit 1
exit 0
