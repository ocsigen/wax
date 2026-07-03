#!/usr/bin/env bash
#
# mutate-wasm.sh [count]
#
# Mutation fuzzer for the wasm-binary *input* path (which no other fuzzer
# exercises: smith and the corpus are always valid, and mutate-wax/-wat feed
# text). Two complementary modes, selected by MODE (default `bytes`):
#
#   MODE=bytes  — blind byte mutation (mutate-wasm.js): 1-3 flips / truncation /
#     LEB-edge bytes / insert-delete on a valid seed, keeping the magic+version
#     header so the mutant reaches the section parser. Targets the DECODER on
#     malformed input: the mutant is almost always malformed, so a clean
#     rejection (123/128) is expected — we hunt only for a CRASH (uncaught
#     exception / signal / timeout) while decoding.
#
#   MODE=struct — structure-aware mutation (`wasm-tools mutate`): 1-3 chained
#     transformations that re-encode the parsed module, so the mutant is
#     STRUCTURALLY valid and gets past the decoder into from_wasm, validation and
#     the round-trip — the surface byte-flips never reach (they die in the outer
#     parser). Here a mutant may be semantically valid or invalid; the oracle's
#     differential, emitter-soundness and round-trip checks carry the signal, not
#     just crashes. Needs wasm-tools; complements bytes, does not replace it.
#
# Seeds default to the valid wasm corpus (fuzz/corpus/valid, from
# build-corpus.sh); override with SEEDS. Parallel across cores (override with
# JOBS, oversubscribed like smith.sh since the oracle is latency-bound). Failing
# mutants are saved under the printed dir.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COUNT="${1:-2000}"
MODE="${MODE:-bytes}"           # bytes (mutate-wasm.js) | struct (wasm-tools mutate)
SEEDS="${SEEDS:-$ROOT/fuzz/corpus/valid}"
JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
KEEP="$ROOT/fuzz/mutate-wasm-findings"
ORACLE="$(dirname "${BASH_SOURCE[0]}")/oracle.sh"
MUT="$(dirname "${BASH_SOURCE[0]}")/mutate-wasm.js"
NODE="${NODE:-node}"
if [ "$MODE" = struct ]; then
  command -v "$WASM_TOOLS" >/dev/null 2>&1 \
    || { echo "wasm-tools not found (needed for MODE=struct)" >&2; exit 2; }
else
  command -v "$NODE" >/dev/null 2>&1 || { echo "node not found (set NODE)" >&2; exit 2; }
fi
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
  local i="$1" cur nxt out n step=0
  cur="$(mktemp --suffix=.wasm)"
  cp "${SEED_FILES[$(( (i * 2654435761) % NSEEDS ))]}" "$cur"
  n=$(( (i % 3) + 1 ))
  while [ "$n" -gt 0 ]; do
    nxt="$(mktemp --suffix=.wasm)"
    # Deterministic per-(mutant, step) seed from the master $SEED so the campaign
    # replays from one number (was $RANDOM — irreproducible).
    local s=$(( SEED + i * 8 + step ))
    local made=0
    if [ "$MODE" = struct ]; then
      # wasm-tools mutate applies one structural transformation; chaining n of
      # them compounds them. It occasionally fails to find a mutation for a seed
      # (exit 3) — keep the current module and move on.
      "$WASM_TOOLS" mutate "$cur" --seed "$s" -o "$nxt" 2>/dev/null && [ -s "$nxt" ] && made=1
    else
      "$NODE" "$MUT" "$cur" "$s" >"$nxt" 2>/dev/null && [ -s "$nxt" ] && made=1
    fi
    if [ "$made" = 1 ]; then mv "$nxt" "$cur"; else rm -f "$nxt"; fi
    step=$((step + 1)); n=$((n - 1))
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
export WAX WASM_TOOLS TIMEOUT WT_FEATURES ORACLE RESULTS KEEP NSEEDS MUT NODE SEED MODE

announce_seed "$(basename "$0") $COUNT"
echo "mutating $COUNT wasm variants ($MODE) from $NSEEDS seeds across $JOBS jobs..." >&2
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
