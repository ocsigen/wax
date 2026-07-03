#!/usr/bin/env bash
#
# wat-cast-const.sh
#
# A deterministic WAT-driven guard on the numeric conversion casts, aimed at the
# blind spot cast-lattice.sh has for OVER-rejection.
#
# cast-lattice.sh drives the casts from *Wax source*: it has no ground truth for
# whether a cast *should* be valid, so it can only flag a crash or a broken
# round-trip of something that COMPILED — a cast the typer wrongly *rejects* but
# [to_wasm] could lower is invisible to it (it treats every clean rejection as an
# intended answer). This script supplies the missing ground truth: it enumerates
# each conversion instruction applied to an edge-value CONSTANT, builds a module
# the reference (wasm-tools) confirms is valid, then round-trips it through Wax —
# so a rejection on the way back is provably an over-rejection.
#
# Const operands are the point. A [local.get] operand (as wat-cast-chain.sh uses)
# decompiles to a typed variable, but a *const* decompiles to a numeric literal,
# and it is the literal casts — an integer-valued float const rendered as a large
# integer literal, then cast — where the typer/[to_wasm] flexible-numeric arms
# disagree (e.g. the [i64.trunc_f64_s (f64.const 2^32)] -> [<big> as i64_s]
# over-rejection). Edge values (0, +-0, powers of two straddling i32/i64/u32,
# i64/f-range limits, inf, nan) probe those arms exhaustively.
#
# For each (instruction x edge const):
#   1. build [(func (result T) (INSTR (SRC.const V)))];
#   2. skip it unless wasm-tools validates it (an out-of-range f32 literal, say);
#   3. round-trip through Wax: wat -> wax -> wasm. A crash or a rejection on
#      either leg is a HIGH finding (a valid module wax mis-handles); and the
#      recompiled binary must still validate (emitter soundness).
# Deterministic, parallel, exits non-zero on any HIGH finding.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v "$WASM_TOOLS" >/dev/null 2>&1; then
  echo "wat-cast-const: wasm-tools not found (needed as the validity oracle)" >&2
  exit 2
fi

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# Conversion instructions: "wat-opcode | source wasm type | result wasm type".
INSTRS=(
  "i32.wrap_i64|i64|i32"
  "i64.extend_i32_s|i32|i64"
  "i64.extend_i32_u|i32|i64"
  "i32.trunc_f32_s|f32|i32"    "i32.trunc_f32_u|f32|i32"
  "i32.trunc_f64_s|f64|i32"    "i32.trunc_f64_u|f64|i32"
  "i64.trunc_f32_s|f32|i64"    "i64.trunc_f32_u|f32|i64"
  "i64.trunc_f64_s|f64|i64"    "i64.trunc_f64_u|f64|i64"
  "i32.trunc_sat_f32_s|f32|i32" "i32.trunc_sat_f32_u|f32|i32"
  "i32.trunc_sat_f64_s|f64|i32" "i32.trunc_sat_f64_u|f64|i32"
  "i64.trunc_sat_f32_s|f32|i64" "i64.trunc_sat_f32_u|f32|i64"
  "i64.trunc_sat_f64_s|f64|i64" "i64.trunc_sat_f64_u|f64|i64"
  "f32.convert_i32_s|i32|f32"  "f32.convert_i32_u|i32|f32"
  "f32.convert_i64_s|i64|f32"  "f32.convert_i64_u|i64|f32"
  "f64.convert_i32_s|i32|f64"  "f64.convert_i32_u|i32|f64"
  "f64.convert_i64_s|i64|f64"  "f64.convert_i64_u|i64|f64"
  "f32.demote_f64|f64|f32"     "f64.promote_f32|f32|f64"
  "i32.reinterpret_f32|f32|i32" "f32.reinterpret_i32|i32|f32"
  "i64.reinterpret_f64|f64|i64" "f64.reinterpret_i64|i64|f64"
  "i32.extend8_s|i32|i32"      "i32.extend16_s|i32|i32"
  "i64.extend8_s|i64|i64"      "i64.extend16_s|i64|i64"  "i64.extend32_s|i64|i64"
)

# Edge-value const literals per wasm type. The float lists include integer-valued
# powers of two straddling the i32/u32/i64 limits — the ones that decompile to a
# large integer literal — plus signed zero, non-integers, the range limits and
# the non-finite values.
I32VALS=(0 1 -1 2147483647 -2147483648 0x7fffffff 0x80000000 0xffffffff)
I64VALS=(0 1 -1 9223372036854775807 -9223372036854775808 0x8000000000000000 4294967296)
FVALS=(0 -0 1 -1 1.5 -1.5 2147483648 4294967296 -4294967296 9223372036854775808
       -9223372036854775808 1e30 -1e30 inf -inf nan nan:0x400000)

vals_for() {
  case "$1" in
    i32) printf '%s\n' "${I32VALS[@]}" ;;
    i64) printf '%s\n' "${I64VALS[@]}" ;;
    f32 | f64) printf '%s\n' "${FVALS[@]}" ;;
  esac
}

# Build the (instr x value) combination list: "label<TAB>module".
COMBOS=()
for spec in "${INSTRS[@]}"; do
  IFS='|' read -r op src out <<<"$spec"
  while IFS= read -r v; do
    COMBOS+=("$op($src.const $v)"$'\t'"(module (func (result $out) ($op ($src.const $v))))")
  done < <(vals_for "$src")
done
N=${#COMBOS[@]}

# Worker: check combinations [first..last]. A combination wasm-tools rejects is
# skipped (not a valid module). A valid one must round-trip through Wax with
# every leg ok and a reference-valid recompiled binary.
cast_worker() {
  local first="$1" last="$2" i label body v out=""
  local p="$RESULTS/w$first" wat="$RESULTS/w$first.wat"
  ERRLOG="$RESULTS/w$first.err"
  for ((i = first; i <= last; i++)); do
    label="${COMBOS[$i]%%$'\t'*}"
    body="${COMBOS[$i]#*$'\t'}"
    printf '%s\n' "$body" >"$wat"
    if ! "$WASM_TOOLS" validate --features "$WT_FEATURES" "$wat" >/dev/null 2>&1; then
      printf 's' >&2; continue   # not a valid module (e.g. out-of-range literal)
    fi
    v="$(classify_wax -i wat -f wax "$wat" -o "$p.wax")"
    if [ "$v" != ok ]; then
      out+="$(finding CASTCONST HIGH "$label" "$v (wat->wax)" "$body")"$'\n'
      printf F >&2; continue
    fi
    v="$(classify_wax -i wax -f wasm "$p.wax" -o "$p.wasm")"
    if [ "$v" != ok ]; then
      out+="$(finding CASTCONST HIGH "$label" "$v (wax->wasm, over-rejection)" "$body")"$'\n'
      printf F >&2; continue
    fi
    if ! wt_validate "$p.wasm"; then
      out+="$(finding CASTCONST HIGH "$label" "recompiled binary invalid: $(head -1 "$p.wasm.err")" "$body")"$'\n'
      printf F >&2; continue
    fi
    printf . >&2
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$first"
}

echo "enumerating $N (cast x edge-const) combinations across $JOBS jobs (frozen wax)..." >&2
chunk=$(((N + JOBS - 1) / JOBS))
for ((w = 0; w < JOBS; w++)); do
  first=$((w * chunk))
  [ "$first" -ge "$N" ] && break
  last=$((first + chunk - 1)); [ "$last" -ge "$N" ] && last=$((N - 1))
  cast_worker "$first" "$last" &
done
wait
echo >&2

REPORT="$RESULTS/report"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); n=${n:-0}
echo "=================== wat-cast-const report ==================="
echo "combinations tested: $N"
echo "findings (crash / over-rejection / unsound emit): $n"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
fi
[ "$n" -gt 0 ] && exit 1
exit 0
