#!/usr/bin/env bash
#
# adaptive-width.sh
#
# The ADAPTIVE-OPERAND dimension of the width-drift family, made deterministic.
# An adaptive operand (a dead-code hole, or an untyped [select] whose arms are
# adaptive — [reparse_adaptive] in from_wasm.ml) does not DEFAULT on a re-parse:
# it takes whatever type its context demands. That breaks every rule of the form
# "an i32 needs no pin, i32 is what a flexible value re-parses to anyway" — the
# rule holds for a value that defaults, not for one that adapts. The founding
# finding (smith-688): [f32.convert_i32_u] over a dead select-of-holes — the
# convert's own [as f32_u] surface became the operand's context, the operand
# re-parsed as f32, and the conversion collapsed to nothing.
#
# The grid crosses every width-sensitive opcode (converts, truncations incl.
# saturating, eqz, wrap, the sign-extends, reinterprets, promote/demote, the
# float methods, i31.get, div/rem/shifts/rotates, the comparisons) with the
# adaptive operand shapes, all on the dead-code stack, and asserts the opcode
# survives BOTH the default and the --faithful round trip. i32-family cells
# whose opcode is the re-parse default anyway are kept as controls.
#
# The blast radius of this class is dead-code FIDELITY (adaptive shapes live on
# the polymorphic stack, so nothing executes); both modules validate, so only
# the opcode comparison sees it — which is why the nightly found smith-688 by
# luck and this sweep checks every known pair on every run.
#
# No cell is exempt. The one shape suspected of a legitimate shared-spelling
# re-fusion — [i64.extend32_s] over a bare hole, whose printed form
# [_ as i64 as i32 as i64_s] carries the surface of [i32.wrap_i64 ;
# i64.extend_i32_s] — in fact re-fuses back to the single [i64.extend32_s] in both
# modes, so it is asserted like the rest.
#
# The survival test is word-boundary anchored, not a substring: [i32.eq] is a
# prefix of [i32.eqz] (and [i64.eq] of [i64.eqz]), so a plain [grep -F] would let
# an eq -> eqz drift — the exact confusable-twin shape this family produces — pass
# vacuously.
#
# Deterministic, parallel, wax-only (no wasm-tools). Exits non-zero on any
# finding. Like every guard here it tests the binary [_build] currently holds and
# never builds one, so run [dune build] first (the sweep's founding 24-cell report
# turned out to be a tree built before the fix it was meant to check).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# ---- The adaptive operand shapes, each a dead-code instruction sequence whose
# top-of-stack the op consumes. For a binary op that is the SECOND operand; the
# first is a bare hole the polymorphic stack supplies. ----
declare -a SHAPE_NAME SHAPE_INSTRS
shape() { SHAPE_NAME+=("$1"); SHAPE_INSTRS+=("$2"); }
shape "hole"       ""
shape "select"     "select"
shape "select-c"   "i32.const 1 select"
shape "select-sel" "select select"

# ---- The width-sensitive ops. Each is "opcode-text|survive-token": the
# round-tripped wat must contain the token. ----
declare -a OPS
op() { OPS+=("$1|${2:-$1}"); }

# Converts: the founding finding's family — the op's own surface is the
# operand's context, so an unpinned adaptive source collapses the conversion.
for w in 32 64; do for s in s u; do
  op "f32.convert_i${w}_${s}"
  op "f64.convert_i${w}_${s}"
done; done
# Truncations, plain and saturating: the float SOURCE width is the erasable part.
for w in 32 64; do for f in 32 64; do for s in s u; do
  op "i${w}.trunc_f${f}_${s}"
  op "i${w}.trunc_sat_f${f}_${s}"
done; done; done
# The one-operand width ops.
op "i32.eqz"; op "i64.eqz"
op "i32.wrap_i64"
op "i32.extend8_s"; op "i32.extend16_s"
op "i64.extend8_s"; op "i64.extend16_s"; op "i64.extend32_s"
op "i32.reinterpret_f32"; op "i64.reinterpret_f64"
op "f32.reinterpret_i32"; op "f64.reinterpret_i64"
op "f64.promote_f32"; op "f32.demote_f64"
for f in 32 64; do for m in sqrt abs ceil floor trunc nearest neg; do
  op "f${f}.${m}"
done; done
op "i31.get_s"; op "i31.get_u"
# Result width = operand width, so an adaptive operand that re-defaults takes the
# opcode's width with it.
for w in 32 64; do for m in clz ctz popcnt; do op "i${w}.${m}"; done; done
for f in 32 64; do for m in min max copysign; do op "f${f}.${m}"; done; done
# Binary width ops (the second operand is a hole from the polymorphic stack).
for w in 32 64; do
  for b in div_s div_u rem_s rem_u shl shr_s shr_u rotl rotr; do
    op "i${w}.${b}"
  done
  for c in eq ne lt_s lt_u gt_s gt_u le_s le_u ge_s ge_u; do
    op "i${w}.${c}"
  done
done
for f in 32 64; do for c in eq ne lt gt le ge; do
  op "f${f}.${c}"
done; done

# ---- The cells. ----
COMBOS=()
for o in "${OPS[@]}"; do
  opcode="${o%%|*}"; token="${o#*|}"
  for i in "${!SHAPE_NAME[@]}"; do
    COMBOS+=("${opcode}/${SHAPE_NAME[$i]}"$'\t'"$token"$'\t'"(module (func (export \"f\") unreachable ${SHAPE_INSTRS[$i]} $opcode drop unreachable))")
  done
done
N=${#COMBOS[@]}

worker() {
  local first="$1" last="$2" i label token body v mode out=""
  local p="$RESULTS/w$first"
  local wat="$p.wat" wax="$p.wax" back="$p.back.wat"
  ERRLOG="$p.err"
  for ((i = first; i <= last; i++)); do
    label="${COMBOS[$i]%%$'\t'*}"
    local rest="${COMBOS[$i]#*$'\t'}"
    token="${rest%%$'\t'*}"
    body="${rest#*$'\t'}"
    printf '%s\n' "$body" >"$wat"
    for mode in "" "--faithful"; do
      v="$(classify_wax -i wat -f wax $mode --error-format short "$wat" -o "$wax")"
      if [ "$v" != ok ]; then
        out+="$(finding ADAPTWIDTH HIGH "$label" "${mode:-default}: $v (wat->wax)" "$body")"$'\n'
        printf F >&2; continue
      fi
      v="$(classify_wax -i wax -f wat "$wax" -o "$back")"
      if [ "$v" != ok ]; then
        out+="$(finding ADAPTWIDTH HIGH "$label" "${mode:-default}: $v (wax->wat)" "$body")"$'\n'
        printf F >&2; continue
      fi
      # Word-boundary anchored: [i32.eq] must not be satisfied by an [i32.eqz].
      if ! grep -qE "${token//./\\.}([^a-z0-9_]|\$)" "$back"; then
        local got
        got="$(grep -oE '[if](32|64)\.[a-z0-9_]+' "$back" | sort -u | tr '\n' ',')"
        out+="$(finding ADAPTWIDTH HIGH "$label" "${mode:-default}: $token gone (found: ${got:-none})" "$body")"$'\n'
        printf F >&2; continue
      fi
    done
    printf . >&2
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$first"
}

echo "adaptive-width: $N op x adaptive-shape cells across $JOBS jobs (frozen wax)..." >&2
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
echo "=================== adaptive-width report ==================="
echo "cells tested: $N"
h=$(grep -c $'\tHIGH\t' "$REPORT" 2>/dev/null); h=${h:-0}
echo "findings: $n  (HIGH: $h)"
if [ "$n" -gt 0 ]; then
  cat "$REPORT"
  exit 1
fi
exit 0
