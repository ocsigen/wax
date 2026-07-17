#!/usr/bin/env bash
#
# wax-lower-fuzz.sh
#
# A deterministic guard on the Wax-specific lowering (to_wasm.ml) that only
# Wax *source* reaches — the surface no wasm/wat corpus decompiles into, so no
# round-trip oracle exercises it. It pairs each construct with a semantically
# equivalent one that must lower to byte-identical wasm:
#
#   * an intrinsic method (`x.rotl(y)`, `x.min(y)`, `x.sqrt()`, …) cannot be a
#     tail call, so `become x.op(…)` must lower exactly like `return x.op(…)`
#     (evaluate the op, then return its value). The binary intrinsics read the
#     operation's type from the wrong node in tail position and asserted, so this
#     also guards against that whole "consult the receiver, not the call node"
#     class;
#   * `x op= e` is defined as `x = x op e`, so the two must lower identically.
#
# For each pair A/B:
#   CRASH    — either side exits with an internal-error / signal code. HIGH.
#   REJECT   — one side is accepted and the other rejected. HIGH.
#   MISMATCH — both compile but to different wasm. HIGH.
#
# Deterministic (exhaustive enumeration, no seed), parallel, wax-only. Exits
# non-zero on any finding.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# Each pair is "label<TAB>wax-A<TAB>wax-B"; A and B must compile to identical wasm.
PAIRS=()
add() { PAIRS+=("$1"$'\t'"$2"$'\t'"$3"); }

# ---- become vs return on intrinsic methods (an intrinsic cannot tail-call, so
# both must evaluate the op and return it). ----
# Binary integer intrinsics (receiver and argument share the type).
for op in rotl rotr; do
  for t in i32 i64; do
    add "become/$op.$t" \
      "fn f(x: $t, y: $t) -> $t { return x.$op(y); }" \
      "fn f(x: $t, y: $t) -> $t { become x.$op(y); }"
  done
done
# Binary float intrinsics.
for op in min max copysign; do
  for t in f32 f64; do
    add "become/$op.$t" \
      "fn f(x: $t, y: $t) -> $t { return x.$op(y); }" \
      "fn f(x: $t, y: $t) -> $t { become x.$op(y); }"
  done
done
# Unary intrinsics (controls: already consulted the receiver, must stay correct).
add "become/clz.i32"   "fn f(x: i32) -> i32 { return x.clz(); }"   "fn f(x: i32) -> i32 { become x.clz(); }"
add "become/popcnt.i64" "fn f(x: i64) -> i64 { return x.popcnt(); }" "fn f(x: i64) -> i64 { become x.popcnt(); }"
add "become/sqrt.f32"  "fn f(x: f32) -> f32 { return x.sqrt(); }"  "fn f(x: f32) -> f32 { become x.sqrt(); }"
add "become/abs.f64"   "fn f(x: f64) -> f64 { return x.abs(); }"   "fn f(x: f64) -> f64 { become x.abs(); }"

# ---- x op= e  vs  x = x op e (compound assignment desugaring). ----
for t in i32 i64; do
  for op in "+" "-" "*" "&" "|" "^" "<<"; do
    add "compound/${op}.$t" \
      "fn f(x: $t, y: $t) -> $t { x = x $op y; x; }" \
      "fn f(x: $t, y: $t) -> $t { x $op= y; x; }"
  done
done
for t in f32 f64; do
  for op in "+" "-" "*"; do
    add "compound/${op}.$t" \
      "fn f(x: $t, y: $t) -> $t { x = x $op y; x; }" \
      "fn f(x: $t, y: $t) -> $t { x $op= y; x; }"
  done
done

N=${#PAIRS[@]}

worker() {
  local first="$1" last="$2" i label a b va vb out=""
  local p="$RESULTS/w$first"
  local awax="$p.a.wax" bwax="$p.b.wax" awasm="$p.a.wasm" bwasm="$p.b.wasm"
  ERRLOG="$p.err"
  for ((i = first; i <= last; i++)); do
    label="${PAIRS[$i]%%$'\t'*}"
    local rest="${PAIRS[$i]#*$'\t'}"
    a="${rest%%$'\t'*}"; b="${rest#*$'\t'}"
    printf '%s\n' "$a" >"$awax"
    printf '%s\n' "$b" >"$bwax"
    va="$(classify_wax -i wax -f wasm "$awax" -o "$awasm")"
    vb="$(classify_wax -i wax -f wasm "$bwax" -o "$bwasm")"
    case "$va,$vb" in
      *crash*)
        out+="$(finding WAXLOWER HIGH "$label" "crash (A=$va B=$vb)" "$b")"$'\n'
        printf F >&2; continue ;;
    esac
    if [ "$va" != "$vb" ]; then
      out+="$(finding WAXLOWER HIGH "$label" "A=$va but B=$vb" "$b")"$'\n'
      printf F >&2; continue
    fi
    if [ "$va" = ok ] && ! cmp -s "$awasm" "$bwasm"; then
      out+="$(finding WAXLOWER HIGH "$label" "equivalent forms lower to different wasm" "$b")"$'\n'
      printf F >&2; continue
    fi
    printf . >&2
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$first"
}

echo "checking $N Wax-lowering equivalence pairs across $JOBS jobs (frozen wax)..." >&2
chunk=$(((N + JOBS - 1) / JOBS))
for ((w = 0; w < JOBS; w++)); do
  first=$((w * chunk))
  [ "$first" -ge "$N" ] && break
  last=$((first + chunk - 1)); [ "$last" -ge "$N" ] && last=$((N - 1))
  worker "$first" "$last" &
done
wait
echo >&2

REPORT="$RESULTS/report"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); n=${n:-0}
echo "=================== wax-lower report ==================="
echo "pairs: $N"
echo "findings (crash / reject / mismatch): $n"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
fi
[ "$n" -gt 0 ] && exit 1
exit 0
