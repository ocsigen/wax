#!/usr/bin/env bash
#
# const-context.sh
#
# Differentially test the constant-expression checkers by placing const-candidate
# expressions into constant positions (globals and element-segment initializers).
#
# Both frontends validate a constant expression arm by arm: the Wasm validator in
# `check_constant_instruction` (lib-wasm/validation.ml) and the Wax typer in
# `constant_instruction` (lib-wax/typing.ml). Each arm independently decides
# "constant or not" for one operator (`ref.i31`, `extern.convert_any`,
# `struct.new`, `array.new_default`, `cont.new`, extended-const arithmetic, a
# `global.get` of an immutable global, …), so any one can drift from what the
# reference actually accepts. Random mutation reaches these only by luck — it has
# to happen to hoist such an expression into a global/elem. This generator does
# it on purpose, sweeping the whole surface.
#
# Each generated module is a plain, valid-shaped WAT with one const initializer;
# oracle.sh supplies the differential (no new oracle logic needed):
#   VALIDATOR_DIFF — wax's WAT validator disagrees with wasm-tools on const
#                    validity (a validator-side arm drifted).
#   UNDER_REJECT   — wax's WAT validator accepts, but wax->wax (decompile +
#                    retype) rejects: the *typer*'s const arm over-rejects a
#                    valid const (the `0 as &extern` = `extern.convert_any
#                    (ref.i31 …)` class this campaign was written for).
#   FALSE_ACCEPT   — wax accepts but emits a binary/text the reference rejects: a
#                    non-const the checker let through.
#   CRASH          — any pipeline exits outside ok/clean-reject. HIGH.
#
# Deterministic given SEED; needs wasm-tools (oracle.sh's reference). Exits
# non-zero on any HIGH finding.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v "$WASM_TOOLS" >/dev/null 2>&1; then
  echo "const-context: wasm-tools not found (oracle.sh needs it)" >&2
  exit 2
fi

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
FUZZ="${FUZZ:-400}"          # random nested variants (on top of the fixed cases)
ORACLE="$(dirname "${BASH_SOURCE[0]}")/oracle.sh"
KEEP="$ROOT/fuzz/const-findings"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"
mkdir -p "$KEEP"

# The module preamble every case shares: the types, the referenceable function,
# and the immutable imported globals a [global.get] const may read. [$feat] is a
# [(@feature …)] annotation (custom-descriptors for the exact-ref cases), empty
# otherwise; wax enables the declared feature and wasm-tools takes --features all.
emit_module() {
  local feat="$1" gtype="$2" init="$3"
  printf '(module\n'
  [ -n "$feat" ] && printf '  (@feature "%s")\n' "$feat"
  cat <<'EOF'
  (type $ft (func))
  (type $ct (cont $ft))
  (type $s (struct (field i32)))
  (type $a (array i32))
  (import "env" "g32" (global $g32 i32))
  (import "env" "g64" (global $g64 i64))
  (import "env" "gext" (global $gext externref))
  (func $f (type $ft))
  (elem declare func $f)
EOF
  printf '  (global %s %s)\n)\n' "$gtype" "$init"
}

# The fixed surface: one (feature | global-type | init) per constant-instruction
# arm, plus a few known-tricky compositions. `|`-separated so a blank feature is
# easy. The last block is deliberately NON-constant — both wax and the reference
# must reject them; if wax accepts, that is a FALSE_ACCEPT the oracle reports.
CASES=(
  '|i32|(i32.const 42)'
  '|i64|(i64.const 42)'
  '|f32|(f32.const 1.5)'
  '|f64|(f64.const 1.5)'
  '|i32|(i32.add (i32.const 1) (i32.const 2))'
  '|i32|(i32.sub (global.get $g32) (i32.const 1))'
  '|i32|(i32.mul (i32.const 3) (global.get $g32))'
  '|i64|(i64.add (global.get $g64) (i64.const 2))'
  '|i32|(global.get $g32)'
  '|externref|(global.get $gext)'
  '|(ref null func)|(ref.null func)'
  '|(ref null extern)|(ref.null extern)'
  '|(ref null $s)|(ref.null $s)'
  '|(ref func)|(ref.func $f)'
  '|(ref $ft)|(ref.func $f)'
  '|(ref i31)|(ref.i31 (i32.const 5))'
  '|(ref i31)|(ref.i31 (i32.sub (global.get $g32) (i32.const 1)))'
  '|(ref extern)|(extern.convert_any (ref.i31 (i32.const 0)))'
  '|(ref null extern)|(extern.convert_any (ref.null any))'
  '|(ref any)|(any.convert_extern (extern.convert_any (ref.i31 (i32.const 0))))'
  '|(ref null any)|(any.convert_extern (global.get $gext))'
  '|(ref $s)|(struct.new $s (i32.const 1))'
  '|(ref $s)|(struct.new $s (i32.mul (i32.const 2) (global.get $g32)))'
  '|(ref $s)|(struct.new_default $s)'
  '|(ref $a)|(array.new $a (i32.const 7) (i32.const 3))'
  '|(ref $a)|(array.new_default $a (i32.const 3))'
  '|(ref $a)|(array.new_default $a (i32.add (i32.const 1) (i32.const 2)))'
  '|(ref $a)|(array.new_fixed $a 2 (i32.const 1) (i32.const 2))'
  '|(ref $ct)|(cont.new $ct (ref.func $f))'
  'custom-descriptors|(ref (exact $s))|(struct.new $s (i32.const 1))'
  'custom-descriptors|(ref null (exact $s))|(ref.null (exact $s))'
  # Non-constant initializers: neither side may accept these.
  '|i32|(i32.and (i32.const 1) (i32.const 1))'
  '|i32|(i32.div_s (i32.const 4) (i32.const 2))'
  '|f32|(f32.neg (f32.const 1.5))'
  '|i32|(i32.eqz (i32.const 0))'
)

# A recursive, type-directed generator of a CONSTANT expression of a given type,
# so the checker arms are exercised deeply composed (the nesting a flat case list
# misses). Every producer is itself constant, so the whole expression is a valid
# const — any rejection is a checker over-rejecting. Seed-derived (masked to stay
# positive across bash's wrapping multiply) so a run replays. [d] is the depth
# budget; a leaf is emitted at 0.
derive() { echo $(( (seed * 1103515245 + $1) & 0x7fffffff )); }
gen() {
  local t="$1" d="$2" seed="$3" r=$(( seed % 100 )) a b
  a=$(derive 12345); b=$(derive 54321)
  if [ "$d" -le 0 ]; then
    case "$t" in
      i32) echo "(i32.const $((seed % 17)))" ;;
      i64) echo "(i64.const $((seed % 17)))" ;;
      f32) echo "(f32.const $((seed % 9)).5)" ;;
      f64) echo "(f64.const $((seed % 9)).5)" ;;
      extern) [ $((r % 2)) = 0 ] && echo '(ref.null extern)' || echo '(global.get $gext)' ;;
      any) echo '(ref.null any)' ;;
      i31) echo "(ref.i31 (i32.const $((seed % 5))))" ;;
      func) echo '(ref.func $f)' ;;
      struct) echo '(struct.new_default $s)' ;;
      array) echo "(array.new_default \$a (i32.const $((seed % 4))))" ;;
      cont) echo '(cont.new $ct (ref.func $f))' ;;
    esac
    return
  fi
  case "$t" in
    i32) case $((r % 4)) in
      0) echo "(i32.const $((seed % 17)))" ;;
      1) echo "(i32.add $(gen i32 $((d-1)) "$a") $(gen i32 $((d-1)) "$b"))" ;;
      2) echo "(i32.sub $(gen i32 $((d-1)) "$a") $(gen i32 $((d-1)) "$b"))" ;;
      3) echo '(global.get $g32)' ;; esac ;;
    i64) case $((r % 4)) in
      0) echo "(i64.const $((seed % 17)))" ;;
      1) echo "(i64.add $(gen i64 $((d-1)) "$a") $(gen i64 $((d-1)) "$b"))" ;;
      2) echo "(i64.mul $(gen i64 $((d-1)) "$a") $(gen i64 $((d-1)) "$b"))" ;;
      3) echo '(global.get $g64)' ;; esac ;;
    f32) echo "(f32.const $((seed % 9)).5)" ;;
    f64) echo "(f64.const $((seed % 9)).5)" ;;
    extern) case $((r % 3)) in
      0) echo '(ref.null extern)' ;;
      1) echo "(extern.convert_any $(gen any $((d-1)) "$a"))" ;;
      2) echo '(global.get $gext)' ;; esac ;;
    any) case $((r % 4)) in
      0) echo "(any.convert_extern $(gen extern $((d-1)) "$a"))" ;;
      1) echo "(ref.i31 $(gen i32 $((d-1)) "$a"))" ;;
      2) gen struct $((d-1)) "$a" ;;
      3) gen array $((d-1)) "$a" ;; esac ;;
    i31) echo "(ref.i31 $(gen i32 $((d-1)) "$a"))" ;;
    func) [ $((r % 2)) = 0 ] && echo '(ref.func $f)' || echo '(ref.null func)' ;;
    struct) case $((r % 2)) in
      0) echo "(struct.new \$s $(gen i32 $((d-1)) "$a"))" ;;
      1) echo '(struct.new_default $s)' ;; esac ;;
    array) case $((r % 3)) in
      0) echo "(array.new \$a $(gen i32 $((d-1)) "$a") $(gen i32 $((d-1)) "$b"))" ;;
      1) echo "(array.new_default \$a $(gen i32 $((d-1)) "$a"))" ;;
      2) echo "(array.new_fixed \$a 2 $(gen i32 $((d-1)) "$a") $(gen i32 $((d-1)) "$b"))" ;; esac ;;
    cont) echo '(cont.new $ct (ref.func $f))' ;;
  esac
}

# Pick a result type, generate a const expression of it at depth 1-4, and wrap it
# in a matching (nullable, so a non-null producer still fits) global type.
rand_const() {
  local seed="$1"
  local types=(i32 i64 f32 f64 extern any i31 func struct array cont)
  local t="${types[$(( seed % ${#types[@]} ))]}" gt
  case "$t" in
    i32) gt=i32 ;; i64) gt=i64 ;; f32) gt=f32 ;; f64) gt=f64 ;;
    extern) gt='(ref null extern)' ;; any) gt='(ref null any)' ;;
    i31) gt='(ref null i31)' ;; func) gt='(ref null func)' ;;
    struct) gt='(ref null $s)' ;; array) gt='(ref null $a)' ;;
    cont) gt='(ref null $ct)' ;;
  esac
  echo "|$gt|$(gen "$t" "$(( seed % 4 + 1 ))" "$seed")"
}

# Worker: emit case [spec] as module [n], run the oracle, keep any finding.
run_one() {
  local spec="$1" n="$2" p="$RESULTS/w$2" out
  ERRLOG="$p.err"
  local m="$p.wat"
  local feat="${spec%%|*}" rest="${spec#*|}"
  local gtype="${rest%%|*}" init="${rest#*|}"
  emit_module "$feat" "$gtype" "$init" >"$m"
  out="$(bash "$ORACLE" "$m" unknown 2>/dev/null)"
  if [ -n "$out" ] && [ -n "$(bash "$ORACLE" "$m" unknown 2>/dev/null)" ]; then
    local keep="$KEEP/const-$n.wat"
    cp "$m" "$keep"
    echo "${out//$m/$keep}" >"$RESULTS/$n"
    printf 'F' >&2
  else
    printf '.' >&2
  fi
}
export -f run_one emit_module
export WAX WASM_TOOLS TIMEOUT WT_FEATURES ORACLE RESULTS KEEP

# Build the full spec list: the fixed cases, then FUZZ random nested variants.
SPECS=("${CASES[@]}")
for ((i = 0; i < FUZZ; i++)); do SPECS+=("$(rand_const "$((SEED + i))")"); done

announce_seed "$(basename "$0")"
echo "const-context: ${#SPECS[@]} const modules across $JOBS jobs..." >&2
idx=0
for spec in "${SPECS[@]}"; do
  ( run_one "$spec" "$idx" ) &
  idx=$((idx + 1))
  while [ "$(jobs -r | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || true; done
done
wait
echo >&2

REPORT="$(mktemp)"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
echo "=================== const-context report ==================="
echo "const modules checked: ${#SPECS[@]}"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null || true)
echo "findings: ${n:-0}"
if [ "${n:-0}" -gt 0 ]; then
  echo
  cut -f2,3 "$REPORT" | sort | uniq -c | sort -rn | sed 's/^/  /'
  echo
  echo "failing modules saved under $KEEP/ — replay with:"
  echo "  bash fuzz/oracle.sh $KEEP/const-<n>.wat unknown"
  echo
  echo "full report: $REPORT"
fi
grep -q $'\tHIGH\t' "$REPORT" && exit 1
exit 0
