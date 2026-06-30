#!/usr/bin/env bash
#
# wax-corpus.sh [wasm-corpus-dir] [outdir]
#
# Build a corpus of Wax *source* files by decompiling every known-valid wasm
# module (default fuzz/corpus/valid, from build-corpus.sh) to .wax. The result
# is a corpus of valid, type-correct Wax — wax's own output — that
#   * feeds the oracle directly (run.sh fuzz/corpus-wax), exercising the
#     wax -> wat/wax/wasm directions the wasm-first corpus never reaches; and
#   * seeds the wax mutation fuzzer (mutate-wax.sh).
#
# Output goes under outdir/valid/ so run.sh treats each file as EXPECT=valid: a
# wax rejection of wax's own output is then a FALSE_REJECT (a printer/parser or
# typer disagreement worth a look). Files wax cannot decompile are skipped.
#
# Parallel across cores (override with JOBS).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC="${1:-$ROOT/fuzz/corpus/valid}"
OUT="${2:-$ROOT/fuzz/corpus-wax}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
[ -d "$SRC" ] || { echo "no wasm corpus at $SRC — run fuzz/build-corpus.sh first" >&2; exit 2; }
rm -rf "$OUT"; mkdir -p "$OUT/valid"

# Worker: decompile one module to wax under $OUT/valid; a byte to stderr marks
# progress (. decompiled, s skipped — wax could not produce wax for it).
decompile_one() {
  local f="$1" base out
  base="$(basename "${f%.*}")"
  out="$OUT/valid/$base.wax"
  if timeout "$TIMEOUT" "$WAX" -i wasm -f wax "$f" -o "$out" 2>/dev/null; then
    printf '.' >&2
  else
    rm -f "$out"; printf 's' >&2
  fi
}
export -f decompile_one
export WAX TIMEOUT OUT

total=$(find "$SRC" -name '*.wasm' | wc -l)
echo "decompiling $total valid wasm modules to wax across $JOBS jobs..." >&2
find "$SRC" -name '*.wasm' -print0 \
  | xargs -0 -P "$JOBS" -I{} bash -c 'decompile_one "$@"' _ {}
echo >&2

n=$(find "$OUT/valid" -name '*.wax' | wc -l)
echo "wax corpus: $n/$total modules decompiled -> $OUT/valid"
