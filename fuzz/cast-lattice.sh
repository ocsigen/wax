#!/usr/bin/env bash
#
# cast-lattice.sh
#
# A deterministic guard over the numeric/reference *cast lattice*. It exists
# because a recurring bug class — the typer accepting a cast that [to_wasm] has
# no instruction to lower, so lowering hits [assert false] — lives in the
# flexible-numeric ([Number]/[Int]/[Float]/[LargeInt]/[Unknown]) arms of
# [cast]/[signed_cast]. The decompiler-seeded oracles (smith -> wax -> mutate)
# never reach those arms: decompiled Wax always carries concrete, explicit
# casts, so a bare [1.5] a later cast would see as abstract [Float] simply never
# arises. Random AST mutation only stumbles onto one lattice cell at a time.
#
# The space is small and enumerable, so we enumerate it. For every
# (source flavour x cast target x signedness) — as a single cast, a two-level
# chain, and a cast feeding a unary intrinsic — we assert two things. First, wax
# never *crashes*: every combination must compile or cleanly reject (both are
# intended answers), never hit [assert false]. Second, a combination that
# compiles to valid wasm must *round-trip* (wax -> wasm -> wax -> wasm) back to
# valid wasm — so the *fused* cast path ([to_wasm] re-expanding a single cast the
# decompiler fused from two) is covered, and a broken round-trip is a finding
# whether it crashes OR merely rejects (a faithful decompilation that no longer
# type-checks / re-emits invalid wasm is the over-rejection / emitter-soundness
# class, e.g. smith-13300, diff-558, which reject cleanly rather than crash). The
# property guarded: the set of casts the typer ACCEPTS must equal the set
# [to_wasm] can LOWER — [cast]/[signed_cast] (typing.ml) and [default_cast]
# (to_wasm.ml) are two hand-maintained tables that must agree cell for cell.
#
# Each combination is its own wax invocation (one bad cast per module — batching
# would let a rejected function's error stop compilation before [to_wasm] runs,
# masking a crash in a sibling function). They are fanned across cores (override
# JOBS) so the several-thousand-combination sweep still finishes in seconds.
#
# Exits non-zero if any combination crashes or fails to round-trip, so it can
# gate CI. Deterministic.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# Source-value flavours: how to produce a value of each type flavour in Wax, and
# a parameter list if the value needs one. The flexible/abstract flavours are the
# interesting ones — a concrete param is pinned and takes the well-trodden path.
#   label | params | expression
SOURCES=(
  "Number|| 0"
  "Int|| (0 | 0)"
  "clz|| (0).clz()"
  "Float|| 0.0"
  "FloatExpr|| (0.0 + 0.0)"
  "LargeInt|| 18446744073709551615"
  "HugeIntFloat|| 18446744073709551616"
  "i32|p: i32| p"
  "i64|p: i64| p"
  "f32|p: f32| p"
  "f64|p: f64| p"
  "v128|p: v128| p"
  "refany|p: &?any| p"
  "i31|p: &?i31| p"
  "extern|p: &?extern| p"
  "reffunc|p: &?func| p"
  "Null|| null"
  "Unknown|| { unreachable; _ }"
  "UnknownRef|| { unreachable; null! }"
)

# Cast targets: numeric types with each signedness / strictness variant, plus the
# reference and v128 targets a numeric or reference source might be cast to. The
# inline function-type targets [&fn(..)] carry a signature that matches no
# declared type, so they mint a fresh type *while type-checking* — the case that
# outran the old subtyping-info snapshot (see the [subtyping_info] memoisation in
# the typer); casting a [&func] source down to one exercises the lowering too.
TARGETS=(
  i32 i32_s i32_u i32_s_strict i32_u_strict
  i64 i64_s i64_u i64_s_strict i64_u_strict
  f32 f32_s f32_u f64 f64_s f64_u
  v128 "&i31" "&?i31" "&any" "&?any" "&extern" "&?extern"
  "&fn(i32) -> i32" "&?fn(i32) -> i32"
)

# Unary intrinsics a cast result might feed (the [clz().to_bits()] class): one
# int-family, one float-family, plus the two reinterpret casts hit every
# (method-family, receiver-family) cell.
METHODS=(to_bits from_bits clz sqrt)

# Second-level targets for the two-level chain: one representative of each
# numeric family x signedness, plus the reference intermediates the fusion
# patterns use, cover the distinct lowering cells without the quadratic blow-up.
CHAIN_T2=(i32 i32_s i64 f32 f32_s f64 "&i31" "&any" "&extern" "&?extern" "&fn(i32) -> i32")

# Build the combination list. Each element is "label<TAB>one-line function"; the
# result is discarded with [_ = (..)] so the function type-checks for any target
# type without a return-type dance, while still lowering the cast in [to_wasm].
COMBOS=()
add() { COMBOS+=("$1"$'\t'"fn f($2) { _ = ($3); }"); }
for src in "${SOURCES[@]}"; do
  IFS='|' read -r slab param sexpr <<<"$src"
  for t1 in "${TARGETS[@]}"; do
    add "$slab as $t1" "$param" "($sexpr) as $t1"
    for m in "${METHODS[@]}"; do
      add "($slab as $t1).$m()" "$param" "(($sexpr) as $t1).$m()"
    done
    for t2 in "${CHAIN_T2[@]}"; do
      add "$slab as $t1 as $t2" "$param" "(($sexpr) as $t1) as $t2"
    done
  done
done
N=${#COMBOS[@]}

# Worker: check the combinations at indices [first..last] in one forked subshell,
# reusing its temp files. A crash on compile, or on either leg of the round-trip
# of a combination that compiled, is written as a finding to $RESULTS/$first.
lattice_worker() {
  local first="$1" last="$2" i label body v out=""
  local wax="$RESULTS/w$first.wax" a="$RESULTS/w$first.a" b="$RESULTS/w$first.b.wax" c="$RESULTS/w$first.c"
  ERRLOG="$RESULTS/w$first.err"
  for ((i = first; i <= last; i++)); do
    label="${COMBOS[$i]%%$'\t'*}"
    body="${COMBOS[$i]#*$'\t'}"
    printf '%s\n' "$body" >"$wax"
    v="$(classify_wax -i wax -f wasm "$wax" -o "$a")"
    if [[ "$v" == crash:* ]]; then
      out+="$(finding CAST HIGH "$label" "$v (compile)" "$body")"$'\n'
      printf F >&2; continue
    fi
    if [ "$v" = ok ]; then
      # The combination compiled to valid wasm, so it must round-trip: decompile
      # (may fuse casts under simplify) then recompile (re-expands) back to valid
      # wasm. Any non-ok on either leg is a finding — not only a crash but a
      # *rejection* (exit 128): a valid module whose faithful decompilation no
      # longer type-checks / re-emits invalid wasm is the over-rejection /
      # emitter-soundness class (e.g. smith-13300, diff-558), which surfaces as a
      # clean reject, not a crash.
      v="$(classify_wax -i wasm -f wax "$a" -o "$b")"
      if [ "$v" != ok ]; then
        out+="$(finding CAST HIGH "$label" "$v (decompile)" "$body")"$'\n'
        printf F >&2; continue
      fi
      v="$(classify_wax -i wax -f wasm "$b" -o "$c")"
      if [ "$v" != ok ]; then
        out+="$(finding CAST HIGH "$label" "$v (recompile-fused)" "$body")"$'\n'
        printf F >&2; continue
      fi
    fi
    printf . >&2
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$first"
}

echo "enumerating $N cast combinations across $JOBS jobs (frozen wax)..." >&2
chunk=$(((N + JOBS - 1) / JOBS))
for ((w = 0; w < JOBS; w++)); do
  first=$((w * chunk))
  [ "$first" -ge "$N" ] && break
  last=$((first + chunk - 1))
  [ "$last" -ge "$N" ] && last=$((N - 1))
  lattice_worker "$first" "$last" &
done
wait
echo >&2

# ---- The single-cast accept/reject matrix: golden + monotonicity ----
#
# The sweep above cannot see an *over-strict* cell: a clean rejection is always
# a passing outcome (that blind spot hid the [null as i64_s] / [i64 as &extern]
# asymmetries). Two relative oracles close it:
#
#   * a golden matrix — the full (source x target) accept/reject table is
#     checked into cast-matrix.golden, so any typer change flips visible cells
#     that a human must review (regenerate with REGEN_CAST_MATRIX=1);
#   * monotonicity — laws of the form "every cast accepted for SUPER must be
#     accepted for SUB", which need no intended table at all: a subtype value
#     (null is a valid &?i31) or the flexible form of a committed type (a
#     literal that could commit to i32) can only be *more* castable.

GOLDEN="$(dirname "${BASH_SOURCE[0]}")/cast-matrix.golden"
MATRIX="$RESULTS/matrix"

matrix_worker() {
  local first="$1" last="$2" i src slab param sexpr t v
  local wax="$RESULTS/m$first.wax" a="$RESULTS/m$first.a"
  ERRLOG="$RESULTS/m$first.err"
  for ((i = first; i <= last; i++)); do
    src="${SOURCES[$((i / ${#TARGETS[@]}))]}"
    t="${TARGETS[$((i % ${#TARGETS[@]}))]}"
    IFS='|' read -r slab param sexpr <<<"$src"
    printf 'fn f(%s) { _ = ((%s) as %s); }\n' "$param" "$sexpr" "$t" >"$wax"
    v="$(classify_wax -i wax -f wasm "$wax" -o "$a")"
    case "$v" in crash:*) v=crash ;; esac
    printf '%s\t%s\t%s\n' "$slab" "$t" "$v" >>"$MATRIX.$first"
  done
}

M=$((${#SOURCES[@]} * ${#TARGETS[@]}))
echo "computing the $M-cell accept/reject matrix..." >&2
chunk=$(((M + JOBS - 1) / JOBS))
for ((w = 0; w < JOBS; w++)); do
  first=$((w * chunk))
  [ "$first" -ge "$M" ] && break
  last=$((first + chunk - 1))
  [ "$last" -ge "$M" ] && last=$((M - 1))
  matrix_worker "$first" "$last" &
done
wait
# Byte-order sort (not locale collation): the row order must be identical on
# every machine, or the golden diff drifts purely because CI runs under a
# different LANG (a UTF-8 locale ignores the '&'/'?'/space in the type labels,
# LANG=C does not). Deterministic order is the whole point of the golden.
LC_ALL=C sort "$MATRIX".* >"$MATRIX"

matrix_failed=0
if [ "${REGEN_CAST_MATRIX:-0}" = 1 ]; then
  cp "$MATRIX" "$GOLDEN"
  echo "cast-matrix.golden regenerated ($M cells) — review the diff." >&2
elif [ -f "$GOLDEN" ]; then
  if ! diff -u "$GOLDEN" "$MATRIX" >"$RESULTS/matrix.diff"; then
    matrix_failed=1
  fi
else
  echo "missing $GOLDEN — run with REGEN_CAST_MATRIX=1 to create it" >&2
  matrix_failed=1
fi

# Monotonicity laws, "SUPER:SUB" = accept(SUPER as T) implies accept(SUB as T).
#   Subsumption: null is a valid value of every nullable reference source;
#   [&?i31] is a valid [&?any].
#   Flexibility: a literal/expression that *could* commit to a concrete type
#   accepts at least the casts the committed type does ([Int] vs [i32],
#   [LargeInt] vs [i64], [Float] vs [f32]/[f64], [Number] vs [Int]/[Float]).
#   Equivalence (both directions): [clz] is an [Int]-flavoured expression,
#   [FloatExpr] a [Float]-flavoured one.
MONO=(
  "i31:Null" "refany:Null" "extern:Null" "reffunc:Null"
  "refany:i31"
  "i32:Int" "i64:LargeInt" "f32:Float" "f64:Float"
  "Int:Number" "Float:Number"
  "Int:clz" "clz:Int" "Float:FloatExpr" "FloatExpr:Float"
  "Float:HugeIntFloat" "HugeIntFloat:Float"
)
declare -A CELL
while IFS=$'\t' read -r s t v; do CELL["$s|$t"]="$v"; done <"$MATRIX"
mono_failed=0
for pair in "${MONO[@]}"; do
  sup="${pair%%:*}" sub="${pair#*:}"
  for t in "${TARGETS[@]}"; do
    if [ "${CELL[$sup|$t]}" = ok ] && [ "${CELL[$sub|$t]}" != ok ]; then
      echo "MONOTONICITY $sup as $t is accepted but $sub as $t is ${CELL[$sub|$t]}"
      mono_failed=$((mono_failed + 1))
    fi
  done
done

REPORT="$RESULTS/report"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); n=${n:-0}
echo "=================== cast-lattice report ==================="
echo "combinations tested: $N"
echo "findings (crash or broken round-trip): $n"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
fi
echo "matrix cells: $M ($(grep -c $'\tok$' "$MATRIX") accepted)"
if [ "$matrix_failed" -gt 0 ]; then
  echo "matrix drift against cast-matrix.golden (REGEN_CAST_MATRIX=1 to accept):"
  sed 's/^/  /' "$RESULTS/matrix.diff" 2>/dev/null | grep '^  [+-][^+-]'
fi
echo "monotonicity violations: $mono_failed"
[ "$n" -gt 0 ] || [ "$matrix_failed" -gt 0 ] || [ "$mono_failed" -gt 0 ] && exit 1
exit 0
