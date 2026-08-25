#!/usr/bin/env bash
#
# atomic-width.sh
#
# The ATOMIC dimension of the width-drift family, made deterministic. An atomic
# method name on a memory receiver carries the ACCESS width only
# ([atomic_rmw_add8] is both [i32.atomic.rmw8.add_u] and [i64.atomic.rmw8.add_u]),
# so the i32/i64 family has to come from somewhere else on a re-parse: a narrow
# store/RMW takes it from the VALUE operand, a narrow load from a trailing
# [as iN_u] cast. On the dead-code stack every one of those operands is a hole,
# which defaults to i32 — so an i64 op re-lowers to its i32 sibling unless the
# printed form pins the width, and the pin has to be reachable by the width
# repair ([Typing]'s [reconcile_widths] / [defaulting_tree]).
#
# That makes atomics the corner of the width family where a NARROWING context is
# as dangerous as a widening one, which is what the founding findings were:
# [i64.atomic.rmw8.sub_u ; i32.wrap_i64] (mutant-3237, mutant-5589) decompiled to
# [m.atomic_rmw_sub8(_, _) as i32], where the wrap reads as an identity cast over
# an i32 RMW. The repair could not place a pin there at all — a memory-method call
# was outside [defaulting_tree] — so it reported the disagreement as unrepairable
# and refused a module [wax check] accepts.
#
# The grid crosses every atomic mnemonic (loads, stores, the seven RMW ops at
# every width, notify and both waits, i32 and i64) with the eraser contexts a
# result can land in — nothing, a wrap, an extend, a width-preserving method then
# a wrap, an [eqz] — and asserts the opcode survives BOTH the default and the
# --faithful round trip. Invalid combinations are skipped, not counted.
#
# EXEMPT: a 32/16/8-bit atomic load whose result is extended to i64 —
# [i32.atomic.load ; i64.extend_i32_u] IS [i64.atomic.load32_u] (same bytes, same
# alignment, same zero-extension), one of the shared spellings the round trip is
# documented to normalise (see CLAUDE.md's --faithful residuals). Every other cell
# must come back with its own opcode.
#
# Blast radius: dead-code FIDELITY, plus — unlike most of the family — a refusal
# to convert at all, since the repair reports an unpinnable disagreement as an
# error. Calibration on the pre-fix binary: 88 findings, all the narrow i64 RMWs
# ([cmpxchg] included, whose two value operands must both be grounded); after, only
# the 4 exempt load cells, which this script skips by name.
#
# Deterministic, parallel, wax-only (no wasm-tools). Exits non-zero on any
# finding. Like every guard here it tests the binary [_build] currently holds and
# never builds one, so run [dune build] first.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# ---- Every atomic mnemonic. ----
OPS=()
for t in i32 i64; do
  OPS+=("$t.atomic.load" "$t.atomic.load8_u" "$t.atomic.load16_u")
  OPS+=("$t.atomic.store" "$t.atomic.store8" "$t.atomic.store16")
  [ "$t" = i64 ] && OPS+=("i64.atomic.load32_u" "i64.atomic.store32")
  for rmw in add sub and or xor xchg cmpxchg; do
    OPS+=("$t.atomic.rmw.$rmw" "$t.atomic.rmw8.${rmw}_u" "$t.atomic.rmw16.${rmw}_u")
    [ "$t" = i64 ] && OPS+=("i64.atomic.rmw32.${rmw}_u")
  done
done
OPS+=("memory.atomic.notify" "memory.atomic.wait32" "memory.atomic.wait64")

# ---- The eraser contexts a result can land in. ----
declare -a CTX_NAME CTX_CODE
ctx() { CTX_NAME+=("$1"); CTX_CODE+=("$2"); }
ctx "bare"     "drop"
ctx "wrap"     $'i32.wrap_i64\n    drop'
ctx "extend"   $'i64.extend_i32_u\n    drop'
ctx "ctz-wrap" $'i64.ctz\n    i32.wrap_i64\n    drop'
ctx "eqz"      $'i32.eqz\n    drop'

# An i32-result atomic LOAD extended to i64 is the same instruction as the i64
# load of that width: exempt by name, not by a weakened comparison.
exempt() {
  case "$1/$2" in
    i32.atomic.load/extend | i32.atomic.load8_u/extend | i32.atomic.load16_u/extend) return 0 ;;
    *) return 1 ;;
  esac
}

COMBOS=()
for op in "${OPS[@]}"; do
  for k in "${!CTX_NAME[@]}"; do
    exempt "$op" "${CTX_NAME[$k]}" && continue
    COMBOS+=("$op"$'\t'"${CTX_NAME[$k]}"$'\t'"${CTX_CODE[$k]}")
  done
done
N=${#COMBOS[@]}

worker() {
  local first="$1" last="$2" i op cname code v mode out="" skipped=0
  local p="$RESULTS/w$first"
  local wat="$p.wat" wax="$p.wax" back="$p.back.wat"
  ERRLOG="$p.err"
  for ((i = first; i <= last; i++)); do
    op="${COMBOS[$i]%%$'\t'*}"
    local rest="${COMBOS[$i]#*$'\t'}"
    cname="${rest%%$'\t'*}"
    code="${rest#*$'\t'}"
    printf '(module (memory 1 1 shared)\n  (func\n    return\n    %s\n    %s))\n' \
      "$op" "$code" >"$wat"
    # Only a combination the module validator accepts is a cell; the rest are not
    # inputs the decompiler owes anything for.
    if [ "$(classify_wax check "$wat")" != ok ]; then
      skipped=$((skipped + 1)); printf s >&2; continue
    fi
    for mode in "" "--faithful"; do
      v="$(classify_wax -i wat -f wax $mode --error-format short "$wat" -o "$wax")"
      if [ "$v" != ok ]; then
        out+="$(finding ATOMICWIDTH HIGH "$op/$cname" \
          "${mode:-default}: $v (wat->wax): $(head -1 "$ERRLOG")" \
          "wax -i wat -f wax $mode <<< the module")"$'\n'
        printf F >&2; continue
      fi
      v="$(classify_wax -i wax -f wat "$wax" -o "$back")"
      if [ "$v" != ok ]; then
        out+="$(finding ATOMICWIDTH HIGH "$op/$cname" \
          "${mode:-default}: $v (wax->wat): $(head -1 "$ERRLOG")" "$op")"$'\n'
        printf F >&2; continue
      fi
      # Word-boundary anchored: [i64.atomic.load] must not be satisfied by
      # [i64.atomic.load32_u].
      if ! grep -qE "${op//./\\.}([^0-9a-z_]|\$)" "$back"; then
        local got
        got="$(grep -oE '[a-z0-9]+\.atomic\.[a-z0-9_.]+' "$back" | sort -u | tr '\n' ',')"
        out+="$(finding ATOMICWIDTH HIGH "$op/$cname" \
          "${mode:-default}: opcode drifted (found: ${got:-none})" "$op")"$'\n'
        printf F >&2; continue
      fi
    done
    printf . >&2
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$first"
  [ "$skipped" -gt 0 ] && printf '%s\n' "$skipped" >"$RESULTS/skip.$first"
  return 0
}

echo "atomic-width: $N mnemonic x eraser-context cells across $JOBS jobs (frozen wax)..." >&2
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
skipped=$(cat "$RESULTS"/skip.* 2>/dev/null | paste -sd+ | bc 2>/dev/null); skipped=${skipped:-0}
echo "=================== atomic-width report ==================="
echo "cells tested: $((N - skipped))  (skipped as invalid: $skipped, of $N)"
h=$(grep -c $'\tHIGH\t' "$REPORT" 2>/dev/null); h=${h:-0}
echo "findings: $n  (HIGH: $h)"
if [ "$n" -gt 0 ]; then
  cat "$REPORT"
  exit 1
fi
exit 0
