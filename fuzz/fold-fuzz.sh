#!/usr/bin/env bash
#
# fold-fuzz.sh
#
# Fuzz the fold/unfold pass (lib-wasm/folding.ml), which the other oracles reach
# only shallowly: oracle.sh sweeps --fold/--unfold for CRASHES but never checks
# that folding PRESERVES the instruction stream, and the corpus's wat files
# exercise barely half of folding's per-opcode arity computation (the exotic
# opcodes — stack switching, GC, SIMD, atomics, 128-bit — and the operand-
# shortfall folding paths stay dark).
#
# It generates (fold-gen.awk) modules densely packed with that opcode variety in
# unbalanced, unfolded form, and pins two confluence identities. Writing F for
# `wax -f wat --fold` and U for `wax -f wat --unfold` (both wat->wat rewrites
# that do not validate):
#
#   CONFLUENCE — U(F(x)) must equal U(x)  (folding must not perturb the stream),
#                and F(U(x)) must equal F(x)  (nor must unfolding). U(·) is the
#                canonical flat form and F(·) the canonical nested form, so a
#                text difference here is a fold/unfold pass that dropped,
#                duplicated or reordered an instruction — a HIGH miscompilation.
#   IDEMPOTENCE— F(F(x)) == F(x) and U(U(x)) == U(x): a normal form is a fixed
#                point of its own rewrite.
#   CRASH      — any --fold/--unfold that exits other than ok/rejected.
#
# Folding runs on UNVALIDATED input, so a checked identity is meaningful even
# for modules that would not type-check; a conversion that cleanly rejects (an
# unbound index folding does resolve) just skips the identity for that input.
#
# Deterministic given SEED. No wasm-tools needed (pure wax text round-trips).
# Parallel across seeds; exits non-zero on any HIGH finding.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
GEN="${GEN:-300}"          # number of modules to generate (0 = use file args)
GENAWK="$(dirname "${BASH_SOURCE[0]}")/fold-gen.awk"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# fold / unfold a wat file to $2; prints the classify_wax bucket.
fold_to()   { classify_wax -f wat --fold   "$1" -o "$2"; }
unfold_to() { classify_wax -f wat --unfold "$1" -o "$2"; }

# Worker: fuzz one wat file. Writes findings to $RESULTS/<n>.
fuzz_one() {
  local in="$1" n="$2" out=""
  local p="$RESULTS/w$n"
  ERRLOG="$p.err"
  local fx="$p.fx.wat" ux="$p.ux.wat" ufx="$p.ufx.wat" fux="$p.fux.wat"
  local ffx="$p.ffx.wat" uux="$p.uux.wat"

  local vf vu
  vf="$(fold_to "$in" "$fx")"
  vu="$(unfold_to "$in" "$ux")"
  case "$vf" in crash:*)
    out+="$(finding FOLD HIGH "$(basename "$in")" "$vf on --fold" \
      "wax -f wat --fold $in")"$'\n'; printf F >&2 ;;
  esac
  case "$vu" in crash:*)
    out+="$(finding FOLD HIGH "$(basename "$in")" "$vu on --unfold" \
      "wax -f wat --unfold $in")"$'\n'; printf F >&2 ;;
  esac

  # Both identities need F(x), U(x) and one further rewrite of each to have
  # succeeded; a clean rejection anywhere just means we skip that identity.
  if [ "$vf" = ok ] && [ "$vu" = ok ]; then
    # U(F(x)) == U(x): folding preserves the instruction stream.
    if [ "$(unfold_to "$fx" "$ufx")" = ok ] && ! diff -q "$ux" "$ufx" >/dev/null 2>&1; then
      out+="$(finding FOLD HIGH "$(basename "$in")" \
        "CONFLUENCE: unfold(fold(x)) != unfold(x) — folding perturbed the stream" \
        "wax -f wat --fold $in -o f.wat && diff <(wax -f wat --unfold $in) <(wax -f wat --unfold f.wat)")"$'\n'
      printf F >&2
    fi
    # F(U(x)) == F(x): unfolding preserves the instruction stream.
    if [ "$(fold_to "$ux" "$fux")" = ok ] && ! diff -q "$fx" "$fux" >/dev/null 2>&1; then
      out+="$(finding FOLD HIGH "$(basename "$in")" \
        "CONFLUENCE: fold(unfold(x)) != fold(x) — unfolding perturbed the stream" \
        "wax -f wat --unfold $in -o u.wat && diff <(wax -f wat --fold $in) <(wax -f wat --fold u.wat)")"$'\n'
      printf F >&2
    fi
    # Idempotence: each normal form is a fixed point of its own rewrite.
    if [ "$(fold_to "$fx" "$ffx")" = ok ] && ! diff -q "$fx" "$ffx" >/dev/null 2>&1; then
      out+="$(finding FOLD HIGH "$(basename "$in")" "IDEMPOTENCE: fold(fold(x)) != fold(x)" \
        "wax -f wat --fold $in -o f.wat && diff f.wat <(wax -f wat --fold f.wat)")"$'\n'; printf F >&2
    fi
    if [ "$(unfold_to "$ux" "$uux")" = ok ] && ! diff -q "$ux" "$uux" >/dev/null 2>&1; then
      out+="$(finding FOLD HIGH "$(basename "$in")" "IDEMPOTENCE: unfold(unfold(x)) != unfold(x)" \
        "wax -f wat --unfold $in -o u.wat && diff u.wat <(wax -f wat --unfold u.wat)")"$'\n'; printf F >&2
    fi
  fi

  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$n"
  printf '.' >&2
}

# Inputs: GEN>0 generates that many modules (fold-gen.awk); otherwise the wat
# files passed as arguments (e.g. the corpus) are used. Generated modules are
# kept only if they parse (the fold-stressing shapes always do, but the guard is
# cheap and mirrors cond-fuzz).
if [ "$GEN" -gt 0 ]; then
  gendir="$RESULTS/gen"; mkdir -p "$gendir"
  i=0; k=0
  while [ "$k" -lt "$GEN" ] && [ "$i" -lt "$((GEN * 2 + 8))" ]; do
    f="$gendir/g$(printf '%05d' "$k").wat"
    awk -v seed="$((SEED + i))" -f "$GENAWK" </dev/null >"$f"
    i=$((i + 1))
    if "$WAX" -i wat -f wat "$f" -o /dev/null 2>/dev/null; then k=$((k + 1)); else rm -f "$f"; fi
  done
  mapfile -t FILES < <(find "$gendir" -type f | sort)
else
  FILES=("$@")
fi
NF=${#FILES[@]}
[ "$NF" -gt 0 ] || { echo "no inputs (set GEN=N or pass .wat files)" >&2; exit 2; }

announce_seed "$(basename "$0")"
echo "fuzzing folding on $NF ${GEN:+generated }modules across $JOBS jobs..." >&2
idx=0
for f in "${FILES[@]}"; do
  ( fuzz_one "$f" "$idx" ) &
  idx=$((idx + 1))
  while [ "$(jobs -r | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || true; done
done
wait
echo >&2

REPORT="$RESULTS/report"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); n=${n:-0}
echo "=================== fold-fuzz report ==================="
echo "modules: $NF"
echo "findings (crash / confluence / idempotence): $n"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
fi
[ "$n" -gt 0 ] && exit 1
exit 0
