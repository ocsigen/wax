#!/usr/bin/env bash
#
# pin-reach.sh
#
# PIN REACHABILITY: whether the width repair can place the pin a decompiled value
# needs, whatever produced that value.
#
# The decompiler does not pin widths where it emits; it RECORDS the type each
# source opcode stated ([Ast.instr]'s [expected]) and lets [Typing]'s
# [reconcile_widths] wrap the value in the identity cast that pins it. Placing that
# cast requires a decision — can a pin on THIS node ground the flexible leaves
# underneath it, or would it convert a real datum? — and that decision is a
# hand-maintained list of node shapes whose result width is their operands'
# ([defaulting_tree]: the arithmetic and bitwise binops, unary neg, a
# width-preserving method, a select, a sequence tail, a narrow atomic RMW's value
# operands). A value-producing shape MISSING from that list is not a silent drift:
# the repair reports the disagreement as unrepairable ("its type is fixed by
# context, not defaulted") and refuses to decompile a module [wax check] accepts,
# which is how the founding findings surfaced (mutant-3237/mutant-5589, an
# [i64.atomic.rmw8.sub_u ; i32.wrap_i64] whose RMW was outside the list).
#
# So this sweep asks the list's own question from the outside: for every way to
# leave an i64 on the DEAD-CODE stack — where operands are holes and nothing but
# the producer states a width — put the value under a narrowing or erasing
# consumer and require that the decompile succeeds, the recompile succeeds, and
# the CONSUMER's opcode is still there afterwards. A vanished [i32.wrap_i64] means
# the produced value re-defaulted to i32 and the narrowing became an identity cast:
# the drift the pin exists to prevent.
#
# The shapes deliberately include the block forms, whose result type is stated by
# an annotation the simplify pass may drop, and the untyped [select], whose arms
# carry no type at all — the two places where "nothing states the width" arises for
# a reason other than a hole. Note a block inside dead code starts a REACHABLE
# frame, so its body cannot be empty: those cells carry a real value inside, which
# is what makes the annotation (not a hole) the thing under test.
#
# Blast radius: a refusal to convert at all — [wax check] accepts, every
# conversion path rejects. Loud, but only reachable through a shape nobody has
# enumerated, which is what this file is for. Calibration against the binary before
# the RMW fix: 8 findings, all of them the narrow i64 RMWs; 0 after.
#
# Deterministic, parallel, wax-only (no wasm-tools). Exits non-zero on any
# finding. Like every guard here it tests the binary [_build] currently holds and
# never builds one, so run [dune build] first.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# ---- Every shape that leaves ONE i64 on the dead-code stack. Operands come from
# the polymorphic stack (holes) wherever the shape allows it, so that the shape
# itself is the only thing that could state the width. ----
declare -a SHAPE_NAME SHAPE_CODE
shape() { SHAPE_NAME+=("$1"); SHAPE_CODE+=("$2"); }
# Arithmetic and bitwise: the result width IS the operands', pinnable through them.
shape "binop-add"    "i64.add"
shape "binop-shl"    "i64.shl"
shape "binop-div"    "i64.div_u"
# A width-preserving method: the pin reaches the receiver through it.
shape "method-clz"   "i64.clz"
shape "method-rotl"  "i64.rotl"
shape "extend8"      "i64.extend8_s"
# A literal: the classic defaulting leaf.
shape "const"        "i64.const 5"
# Selects: typed carries its type, untyped carries none.
shape "select-typed" "select (result i64)"
shape "select-untyped" "select"
# The block forms. A block in dead code starts a REACHABLE frame, so each body
# holds a real value; the result ANNOTATION is what states the width here, and the
# simplify pass may drop it.
shape "block"        $'block (result i64)\n    i64.const 1\n    end'
shape "block-br"     $'block (result i64)\n    i64.const 1\n    br 0\n    end'
shape "block-add"    $'block (result i64)\n    i64.const 1\n    i64.const 2\n    i64.add\n    end'
shape "block-param"  $'block (param i64) (result i64)\n    end'
shape "loop"         $'loop (result i64)\n    i64.const 1\n    end'
shape "if"           $'if (result i64)\n    i64.const 1\n    else\n    i64.const 2\n    end'
shape "try_table"    $'try_table (result i64)\n    i64.const 1\n    end'
# Shapes whose type is fixed by a declaration or signature: no pin is needed, and
# the repair must not want one (a control group).
shape "tee"          "local.tee 0"
shape "global"       "global.get 0"
shape "call"         "call 1"
shape "load"         "i64.load8_u"
shape "lane"         "i64x2.extract_lane 0"
# The atomic corner: the value operand picks the family (fuzz/atomic-width.sh
# sweeps it exhaustively; these two keep this grid's calibration honest).
shape "atomic-rmw"   "i64.atomic.rmw8.sub_u"
shape "atomic-cmpxchg" "i64.atomic.rmw16.cmpxchg_u"
shape "atomic-load"  "i64.atomic.load8_u"

# ---- The consumers whose opcode must survive. Each names the token to look for:
# its absence is the drift. ----
declare -a CTX_NAME CTX_CODE CTX_TOKENS
ctx() { CTX_NAME+=("$1"); CTX_CODE+=("$2"); CTX_TOKENS+=("$3"); }
ctx "wrap"     $'i32.wrap_i64\n    drop'                  "i32.wrap_i64"
ctx "eqz"      $'i64.eqz\n    drop'                       "i64.eqz"
ctx "ctz-wrap" $'i64.ctz\n    i32.wrap_i64\n    drop'     "i64.ctz i32.wrap_i64"

COMBOS=()
for s in "${!SHAPE_NAME[@]}"; do
  for c in "${!CTX_NAME[@]}"; do
    COMBOS+=("${SHAPE_NAME[$s]}/${CTX_NAME[$c]}"$'\t'"${CTX_TOKENS[$c]}"$'\t'"${SHAPE_CODE[$s]}"$'\t'"${CTX_CODE[$c]}")
  done
done
N=${#COMBOS[@]}

worker() {
  local first="$1" last="$2" i label tokens shape code v mode out="" skipped=0 tok
  local p="$RESULTS/w$first"
  local wat="$p.wat" wax="$p.wax" back="$p.back.wat"
  ERRLOG="$p.err"
  for ((i = first; i <= last; i++)); do
    label="${COMBOS[$i]%%$'\t'*}"
    local r1="${COMBOS[$i]#*$'\t'}"
    tokens="${r1%%$'\t'*}"
    local r2="${r1#*$'\t'}"
    shape="${r2%%$'\t'*}"
    code="${r2#*$'\t'}"
    # A shared memory, an i64 global, an i64 param and local, and a second
    # function returning i64: everything the shapes above refer to.
    { printf '(module (memory 1 1 shared) (global (mut i64) (i64.const 0))\n'
      printf '  (func (param $p i64) (local $l i64)\n    return\n    %s\n    %s)\n' "$shape" "$code"
      printf '  (func (result i64) i64.const 1))\n'; } >"$wat"
    if [ "$(classify_wax check "$wat")" != ok ]; then
      skipped=$((skipped + 1)); printf s >&2; continue
    fi
    for mode in "" "--faithful"; do
      v="$(classify_wax -i wat -f wax $mode --error-format short "$wat" -o "$wax")"
      if [ "$v" != ok ]; then
        out+="$(finding PINREACH HIGH "$label" \
          "${mode:-default}: $v (wat->wax): $(head -1 "$ERRLOG")" "$shape")"$'\n'
        printf F >&2; continue
      fi
      v="$(classify_wax -i wax -f wat "$wax" -o "$back")"
      if [ "$v" != ok ]; then
        out+="$(finding PINREACH HIGH "$label" \
          "${mode:-default}: $v (wax->wat): $(head -1 "$ERRLOG")" "$shape")"$'\n'
        printf F >&2; continue
      fi
      # Word-boundary anchored: [i64.eq] is a prefix of [i64.eqz], and
      # [i32.wrap_i64] must not be satisfied by a longer mnemonic.
      for tok in $tokens; do
        if ! grep -qE "${tok//./\\.}([^a-z0-9_]|\$)" "$back"; then
          local got
          got="$(grep -oE 'i(32|64)\.[a-z0-9_]+' "$back" | sort -u | tr '\n' ',')"
          out+="$(finding PINREACH HIGH "$label" \
            "${mode:-default}: $tok gone — the value re-defaulted (found: ${got:-none})" \
            "$shape")"$'\n'
          printf F >&2
        fi
      done
    done
    printf . >&2
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$first"
  [ "$skipped" -gt 0 ] && printf '%s\n' "$skipped" >"$RESULTS/skip.$first"
  return 0
}

echo "pin-reach: $N producer-shape x consumer cells across $JOBS jobs (frozen wax)..." >&2
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
echo "=================== pin-reach report ==================="
echo "cells tested: $((N - skipped))  (skipped as invalid: $skipped, of $N)"
h=$(grep -c $'\tHIGH\t' "$REPORT" 2>/dev/null); h=${h:-0}
echo "findings: $n  (HIGH: $h)"
if [ "$n" -gt 0 ]; then
  cat "$REPORT"
  exit 1
fi
exit 0
