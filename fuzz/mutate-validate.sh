#!/usr/bin/env bash
#
# mutate-validate.sh [count]
#
# Soundness oracle for HAND-WRITTEN Wax. The differential oracle (diff-validate.sh)
# only tests wax's type checker on *decompiled* wasm, which always carries the
# explicit casts wax itself inserts — so it can never exercise the implicit
# coercions and flexible-literal defaults a human writes. This harness fills that
# gap: it AST-mutates a valid .wax seed (fuzz_mutate) and checks the one thing that
# must hold on ANY input wax accepts —
#
#   UNSOUND — wax's type checker accepts the mutant (`--validate` passes) but the
#             binary it emits is rejected by the reference interpreter. wax's
#             source typing is too lenient: it let through something with no valid
#             wasm translation.
#   CRASH   — wax crashed (uncaught exception / signal / timeout) type-checking or
#             emitting a mutant it did not cleanly reject.
#
# A wax *rejection* of a mutant is fine (mutants are usually ill-typed) and ignored.
#
# The ground truth is the spec REFERENCE interpreter (REF, default
# ~/sources/Wasm/interpreter/wasm) — the same one diff-validate.sh uses, and the
# reason this does not need wasm-tools. Two precautions keep it honest:
#   * seeds are pre-filtered to those whose unmutated binary the reference can
#     decode+validate, dropping modules that use a proposal the REF build lacks
#     (e.g. stack switching / cont types, which decode as "malformed definition
#     type"); and
#   * a reference *decoding* error on a mutant is ignored (a graft dragged in an
#     unsupported proposal) — only a *validation* rejection counts as UNSOUND.
#
# NB fuzz_mutate only edits literals (to edge values) and cast targets, plus
# subtree grafts, so it under-explores the implicit-coercion patterns this class
# lives in; reviewing the flexible-literal arms of lib-wax/typing.ml directly is
# the higher-signal method. Treat a clean run as corroboration, not proof.
#
# Usage: mutate-validate.sh [count]              (default: 3000 mutants)
#        REF=/path/to/wasm SEEDS=dir  mutate-validate.sh ...
# Seeds come from fuzz/corpus-wax/valid (run fuzz/wax-corpus.sh first).
# Failing mutants (.wax, and .wasm for UNSOUND) are saved under
# fuzz/mutate-sound-findings/.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REF="${REF:-$HOME/sources/Wasm/interpreter/wasm}"
COUNT="${1:-3000}"
SEEDDIR="${SEEDS:-$ROOT/fuzz/corpus-wax/valid}"
MUT="${MUT:-$ROOT/_build/default/src/bin/fuzz_mutate.exe}"
# Latency-bound (fork/exec + IO wait), so oversubscribe like the sibling harnesses.
JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
KEEP="$ROOT/fuzz/mutate-sound-findings"

[ -x "$MUT" ] || { echo "fuzz_mutate not built — run 'dune build' first" >&2; exit 2; }
[ -x "$REF" ] || { echo "reference interpreter not found at $REF (set REF=...)" >&2; exit 2; }
[ -d "$SEEDDIR" ] && [ -n "$(find "$SEEDDIR" -name '*.wax' -print -quit)" ] \
  || { echo "no wax seeds at $SEEDDIR — run fuzz/wax-corpus.sh first" >&2; exit 2; }

mkdir -p "$KEEP"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT

# --- Pre-filter seeds to ones the reference can decode+validate unmutated. ---
# (Parallel: a wax compile + a ref decode per seed.) A seed the REF build cannot
# handle would make every mutant of it a false positive.
filter_one() {
  local f="$1" b
  b="$(mktemp --suffix=.wasm)"
  if "$WAX" -i wax "$f" -f wasm --validate -o "$b" 2>/dev/null && [ -s "$b" ] \
     && "$REF" -d "$b" >/dev/null 2>&1; then
    echo "$f"
  fi
  rm -f "$b"
}
export -f filter_one
export WAX REF
echo "filtering seeds by reference-decodability..." >&2
find "$SEEDDIR" -name '*.wax' \
  | xargs -P "$JOBS" -I{} bash -c 'filter_one "$@"' _ {} >"$RESULTS/seeds"
mapfile -t SEEDS_ARR <"$RESULTS/seeds"
NSEEDS=${#SEEDS_ARR[@]}
echo "usable seeds: $NSEEDS" >&2
[ "$NSEEDS" -gt 0 ] || { echo "no reference-decodable seeds" >&2; exit 2; }

# Persist a failing mutant and record its finding line.
save() {
  local i="$1" msg="$2" wax="$3" bin="${4:-}"
  cp "$wax" "$KEEP/mut-$i.wax"
  [ -n "$bin" ] && cp "$bin" "$KEEP/mut-$i.wasm"
  echo "FINDING	$msg	$KEEP/mut-$i.wax" >"$RESULTS/$i"
}

# Run one mutant. Mutant [i] takes seed [i mod NSEEDS] and mutation seed [i], so
# workers need no shared RNG and any finding reproduces from its index.
mutate_one() {
  local i="$1" seed v
  seed="${SEEDS_ARR[$((i % NSEEDS))]}"
  "$MUT" "$seed" "$i" >"$mwax" 2>/dev/null || { printf 's' >&2; return 0; }
  # wax's own verdict (its source type checker), then emit.
  v="$(classify_wax -i wax "$mwax" -f wasm -o "$mbin" --validate)"
  case "$v" in
    crash:*) save "$i" "CRASH: wax $v on a mutant it did not reject" "$mwax"
             printf 'F' >&2; return 0 ;;
    rejected) printf '.' >&2; return 0 ;;   # ill-typed mutant, correctly rejected
  esac
  [ -s "$mbin" ] || { printf '.' >&2; return 0; }
  # wax accepted — the emitted binary must satisfy the reference too.
  if ! "$REF" -d "$mbin" >/dev/null 2>"$referr"; then
    # A decoding error is an unsupported proposal a graft pulled in, not a bug;
    # only a validation rejection means wax emitted ill-typed wasm.
    if grep -qi "decoding error" "$referr"; then printf 'd' >&2; return 0; fi
    save "$i" "UNSOUND: wax accepts but the reference rejects its binary: $(head -1 "$referr")" "$mwax" "$mbin"
    printf 'F' >&2; return 0
  fi
  printf '.' >&2
}

# One worker: allocate its temp files once, then run a contiguous index range,
# reusing them (batched like diff-validate.sh to avoid per-mutant process spawn).
mutate_worker() {
  local first="$1" last="$2" i
  local mwax mbin referr ERRLOG
  mwax="$(mktemp --suffix=.wax)"; mbin="$(mktemp --suffix=.wasm)"
  referr="$(mktemp)"; ERRLOG="$(mktemp)"
  trap 'rm -f "$mwax" "$mbin" "$referr" "$ERRLOG"' RETURN
  for ((i = first; i <= last; i++)); do mutate_one "$i"; done
}

rm -f "$KEEP"/mut-*.wax "$KEEP"/mut-*.wasm 2>/dev/null
chunk=$(((COUNT + JOBS - 1) / JOBS))
for ((w = 0; w < JOBS; w++)); do
  first=$((w * chunk + 1))
  [ "$first" -gt "$COUNT" ] && break
  last=$((first + chunk - 1))
  [ "$last" -gt "$COUNT" ] && last="$COUNT"
  mutate_worker "$first" "$last" &
done
wait
echo >&2

echo "================= mutation soundness report ================="
n="$(cat "$RESULTS"/[0-9]* 2>/dev/null | grep -c . || true)"
echo "mutants checked: $COUNT   (usable seeds: $NSEEDS)"
echo "findings: $n"
if [ "$n" -gt 0 ]; then
  echo
  cat "$RESULTS"/[0-9]* | sort | sed 's/^/  /'
fi
[ "$n" -gt 0 ] && exit 1
exit 0
