#!/usr/bin/env bash
#
# wat-corpus.sh [smith-count] [smith-bytes]
#
# Build a corpus of WAT source files to seed the WAT-mutation fuzzer
# (mutate-wat.sh). Like wax-corpus.sh but emits wat instead of wax: every valid
# wasm module (the spec corpus from build-corpus.sh, plus `smith-count` smith
# modules — default 1000 at `smith-bytes`=8192 — for complex, varied syntax) is
# converted to .wat with wax. The seeds exercise every WAT literal position
# (consts, memargs, vec lanes, string escapes), which the text mutator then
# perturbs with edge values.
#
# Output: fuzz/corpus-wat/valid/ (override SRC for the spec source, OUT for the
# output dir). Parallel across cores (override with JOBS).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SMITH_COUNT="${1:-1000}"
SMITH_BYTES="${2:-8192}"
SRC="${SRC:-$ROOT/fuzz/corpus/valid}"
OUT="${OUT:-$ROOT/fuzz/corpus-wat}"
# Conversion is latency-bound (a short-lived wax fork per module), so
# oversubscribe to fill the idle cores (like smith.sh) — ~4x the core count.
JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
rm -rf "$OUT"; mkdir -p "$OUT/valid"
export WAX WASM_TOOLS TIMEOUT OUT SMITH_BYTES SMITH_FLAGS

decompile_one() {
  local f="$1" out
  out="$OUT/valid/$(basename "${f%.*}").wat"
  if timeout "$TIMEOUT" "$WAX" -i wasm -f wat "$f" -o "$out" 2>/dev/null; then
    printf '.' >&2
  else
    rm -f "$out"; printf 's' >&2
  fi
}
export -f decompile_one

smith_one() {
  local i="$1" seed mod
  seed="$(mktemp)"; mod="$(mktemp --suffix=.wasm)"
  rand_bytes "$SEED-$i" "$SMITH_BYTES" >"$seed"
  if "$WASM_TOOLS" smith $SMITH_FLAGS "$seed" -o "$mod" 2>/dev/null \
    && timeout "$TIMEOUT" "$WAX" -i wasm -f wat "$mod" -o "$OUT/valid/smith-$i.wat" 2>/dev/null; then
    printf '.' >&2
  else
    rm -f "$OUT/valid/smith-$i.wat"; printf 's' >&2
  fi
  rm -f "$seed" "$mod"
}
export -f smith_one

if [ -d "$SRC" ]; then
  spec=$(find "$SRC" -name '*.wasm' | wc -l)
  echo "converting $spec spec-corpus modules to wat across $JOBS jobs..." >&2
  find "$SRC" -name '*.wasm' -print0 \
    | xargs -0 -P "$JOBS" -I{} bash -c 'decompile_one "$@"' _ {}
  echo >&2
else
  echo "no wasm corpus at $SRC (run fuzz/build-corpus.sh) — using smith seeds only" >&2
fi

if [ "$SMITH_COUNT" -gt 0 ]; then
  echo "generating + converting $SMITH_COUNT smith modules ($SMITH_BYTES bytes) across $JOBS jobs..." >&2
  seq 1 "$SMITH_COUNT" | xargs -P "$JOBS" -I{} bash -c 'smith_one "$@"' _ {}
  echo >&2
fi

n=$(find "$OUT/valid" -name '*.wat' | wc -l)
echo "wat corpus: $n seeds -> $OUT/valid"
