#!/usr/bin/env bash
#
# block-exits.sh
#
# The BLOCK-EXIT dimension, made deterministic. A block whose result is INFERRED
# (a Wax block in expression position with no `=> T`) gets that result from the
# values reaching its exit: the fall-through plus every value branched to its
# label. The rule the typer must enforce is that EVERY reachable exit delivers the
# result, exactly as for a declared one — a block one of whose exits delivers
# nothing would lower to a wasm block whose declared result its body never leaves,
# which the validator then rejects. So a gap here is an UNDER-REJECTION: `wax
# check` accepts a module the conversion refuses, and the surface that reports it
# is the lowering's validation rather than the typer, at whatever span survives
# the lowering.
#
# The dimension is easy to get subtly wrong because the decision is not local to
# one exit. "Delivers nothing" is only an error relative to the OTHER exits (a
# block every exit of which delivers nothing is simply void), and an `if` types
# its arms in order — so a check made as each exit is met sees a different
# `collected` list depending on which arm came first. The founding finding
# (mutant-2939) is exactly that asymmetry: an empty `else` was reported, an empty
# `then` was not.
#
# The grid crosses the five inferring block forms with every pair of exit shapes
# — nothing, a value, a `br` with and without one, and the two divergences — in
# both expression contexts (a `let` binding and a discard), and asserts that the
# typer's verdict AGREES with the conversion's. It is an agreement test, not an
# accept/reject one: which cells are legal is the type system's business, and both
# surfaces must say the same thing about each.
#
# Blast radius: a module the typer wrongly accepts is caught downstream here, so
# the user-visible damage is a bad diagnostic surface rather than a miscompile —
# except that the same acceptance reaches `to_wasm` first, which trusts its input
# by contract, so a shape the validator does not happen to reject is a real
# miscompile. That is the reason to sweep the whole grid rather than the one cell
# the mutation fuzzer found.
#
# Deterministic, parallel, wax-only (no wasm-tools). Exits non-zero on any
# finding. Like every guard here it tests the binary [_build] currently holds and
# never builds one, so run [dune build] first.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# ---- The exit shapes, each a statement sequence placed in a block body. ----
declare -a SHAPE_NAME SHAPE_CODE
shape() { SHAPE_NAME+=("$1"); SHAPE_CODE+=("$2"); }
shape "nothing"  ""
shape "value"    "7;"
shape "br-value" "br 'l 7;"
shape "br-void"  "br 'l;"
shape "unreach"  "unreachable;"
shape "return"   "return;"

# ---- The inferring block forms. Each takes two exit shapes: for [if] they are
# the two arms, for the single-body forms the two leading statements (so a [br]
# followed by a fall-through exercises the same "one exit delivers, one does not"
# shape the arms do). ----
declare -a FORM_NAME
FORM_NAME=(if do loop try try_table)

form_body() {
  local form="$1" a="$2" b="$3"
  case "$form" in
    if)        printf '        if c {\n            %s\n        } else {\n            %s\n        }\n' "$a" "$b" ;;
    do)        printf "        'l: do {\n            %s\n            %s\n        }\n" "$a" "$b" ;;
    loop)      printf "        'l: loop () {\n            %s\n            %s\n        }\n" "$a" "$b" ;;
    try)       printf "        'l: try {\n            %s\n            %s\n        } catch []\n" "$a" "$b" ;;
    try_table) printf "        'l: try_table {\n            %s\n            %s\n        }\n" "$a" "$b" ;;
  esac
}

# ---- The cells. ----
COMBOS=()
for form in "${FORM_NAME[@]}"; do
  for i in "${!SHAPE_NAME[@]}"; do
    for j in "${!SHAPE_NAME[@]}"; do
      body="$(form_body "$form" "${SHAPE_CODE[$i]}" "${SHAPE_CODE[$j]}")"
      # Two expression contexts: a binding (the result is named) and a discard
      # (it is consumed on the spot). Both infer; neither annotates.
      COMBOS+=("$form/${SHAPE_NAME[$i]}+${SHAPE_NAME[$j]}/let"$'\t'"fn h(c: i32) {
    let x =
$body;
}")
      COMBOS+=("$form/${SHAPE_NAME[$i]}+${SHAPE_NAME[$j]}/drop"$'\t'"fn h(c: i32) {
    _ =
$body;
}")
    done
  done
done
N=${#COMBOS[@]}

worker() {
  local first="$1" last="$2" i label src v_check v_conv out=""
  local p="$RESULTS/w$first"
  local wax="$p.wax"
  ERRLOG="$p.err"
  for ((i = first; i <= last; i++)); do
    label="${COMBOS[$i]%%$'\t'*}"
    src="${COMBOS[$i]#*$'\t'}"
    printf '%s\n' "$src" >"$wax"
    v_check="$(classify_wax check "$wax")"
    v_conv="$(classify_wax -i wax -f wat --error-format short "$wax" -o /dev/null)"
    if [ "$v_check" != "$v_conv" ]; then
      # The typer accepting what the conversion refuses is the under-rejection
      # this sweep exists for; the converse (a shape only the conversion accepts)
      # is an over-rejection, equally a disagreement.
      local kind=UNDER_REJECT
      [ "$v_check" = rejected ] && kind=OVER_REJECT
      out+="$(finding BLOCKEXIT HIGH "$label" "$kind: check=$v_check convert=$v_conv" "$src")"$'\n'
      printf F >&2
      continue
    fi
    case "$v_check" in
      crash*) out+="$(finding BLOCKEXIT HIGH "$label" "$v_check" "$src")"$'\n'; printf F >&2; continue ;;
    esac
    printf . >&2
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$first"
}

echo "block-exits: $N form x exit-pair x context cells across $JOBS jobs (frozen wax)..." >&2
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
echo "=================== block-exits report ==================="
echo "cells tested: $N"
h=$(grep -c $'\tHIGH\t' "$REPORT" 2>/dev/null); h=${h:-0}
echo "findings: $n  (HIGH: $h)"
if [ "$n" -gt 0 ]; then
  cat "$REPORT"
  exit 1
fi
exit 0
