#!/usr/bin/env bash
#
# drop-width.sh
#
# A deterministic guard on the *width-eraser* class (ROADMAP.md §1). A "width
# eraser" is any consumer whose Wax surface syntax does not carry its operand's
# width, so an anchor-free literal tree under it re-defaults to i32 on re-parse —
# silently changing the operand's width and, for a non-mod-2^32-homomorphic op
# (`div`/`rem`/`>>`/`<<`/`rot`), its VALUE. Confirmed erasers: `drop`, comparisons,
# `eqz`, `i32.wrap_i64`, a truncation's source float width, the value operand of a
# narrow i64 store (`i64.store8/16/32` — its method name carries only the access
# width), and either arm of a `select` (whose `?:` surface carries no result
# type, so the arms must be pinned or an interposed eraser cannot reach them).
# All are invisible to every validity oracle — both the original and the drifted
# module validate; only execution sees the wrong value / introduced trap.
#
# The space is small and enumerable, so we enumerate it: each eraser wraps a
# width-sensitive i64 tree (and the truncations wrap an f32/f64 const), round-trip
# `wat -> wax -> wat`, and assert the load-bearing opcode survives at its original
# width. Examples of what regresses without the fix:
#   drop (i64.div_u 1 (2^31 + 2^31))   -> i32.div_u, divisor 0: a trap
#   i32.wrap_i64 (i64.shr_u 4096 40)   -> i32.shr_u, count masked to 8: 0 -> 16
#   (i64.shr_u 4096 40) == 0           -> i32 shift: true -> false
#   i64.trunc_f32_u (f32.const ..)     -> i64.trunc_f64_u: corner-case value/trap
#
# Deterministic, parallel, wax-only (no wasm-tools). Exits non-zero on any finding.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# Each combination is "label<TAB>expected-opcode<TAB>module": the round-tripped
# wat must still contain the opcode. Built below.
COMBOS=()
add() { COMBOS+=("$1"$'\t'"$2"$'\t'"$3"); }

# ---- Width-sensitive i64 subtrees: all-literal, straddling 2^31/2^32 so the
# i32 and i64 lattices diverge. Each is a value that changes with width. ----
declare -a INNER_EXPR INNER_OP
add_inner() { INNER_EXPR+=("$1"); INNER_OP+=("$2"); }
# div/rem: divisor is 2^32 (nonzero i64, but 0 in i32 -> trap / wrong quotient)
add_inner "(i64.div_u (i64.const 1) (i64.add (i64.const 2147483648) (i64.const 2147483648)))" "i64.div_u"
add_inner "(i64.rem_u (i64.const 7) (i64.add (i64.const 2147483648) (i64.const 2147483648)))" "i64.rem_u"
add_inner "(i64.div_s (i64.const 1) (i64.mul (i64.const 2147483648) (i64.const 2)))" "i64.div_s"
# shifts: count >= 32, so masking to the wrong width changes the result
add_inner "(i64.shr_u (i64.const 4096) (i64.const 40))" "i64.shr_u"
add_inner "(i64.shr_s (i64.const -1) (i64.const 40))" "i64.shr_s"
add_inner "(i64.shl (i64.const 1) (i64.const 40))" "i64.shl"
# method-form ops (width baked in at the receiver): rotate masks like a shift,
# clz/ctz/popcnt yield a width-dependent count
add_inner "(i64.rotl (i64.const 1) (i64.const 40))" "i64.rotl"
add_inner "(i64.rotr (i64.const 1) (i64.const 40))" "i64.rotr"
add_inner "(i64.clz (i64.const 5))" "i64.clz"
add_inner "(i64.ctz (i64.const 1024))" "i64.ctz"
add_inner "(i64.popcnt (i64.const -1))" "i64.popcnt"

# ---- Erasers: each takes a width-sensitive i64 tree E and yields a func body.
# The tree's opcode must survive the round-trip. ----
for i in "${!INNER_EXPR[@]}"; do
  E="${INNER_EXPR[$i]}"; OP="${INNER_OP[$i]}"
  add "drop $OP"  "$OP" "(module (func (export \"f\") (drop $E)))"
  add "wrap $OP"  "$OP" "(module (func (export \"f\") (result i32) (i32.wrap_i64 $E)))"
  add "eqz $OP"   "$OP" "(module (func (export \"f\") (result i32) (i64.eqz $E)))"
  add "eq0 $OP"   "$OP" "(module (func (export \"f\") (result i32) (i64.eq $E (i64.const 0))))"
  add "ltu $OP"   "$OP" "(module (func (export \"f\") (result i32) (i64.lt_u $E (i64.const 3))))"
  # comparison with the tree on the RIGHT (pin must land on either side)
  add "eq0' $OP"  "$OP" "(module (func (export \"f\") (result i32) (i64.eq (i64.const 0) $E)))"
done

# The i32 counterpart of each eraser is a control: i32 is the re-parse default,
# so these must pass trivially (a plain i64->i32 boundary check).
add "drop i32.shr_u (control)" "i32.shr_u" \
  "(module (func (export \"f\") (drop (i32.shr_u (i32.const 4096) (i32.const 40)))))"

# ---- Narrow i64 stores: [i64.store8/16/32] carries the access width in its
# method name only; the value's i32/i64 type is recovered from the operand, so a
# width-sensitive i64 value re-defaults to i32 and the stored byte changes (the
# value is the eraser; the address is always i32). ----
for i in "${!INNER_EXPR[@]}"; do
  E="${INNER_EXPR[$i]}"; OP="${INNER_OP[$i]}"
  for s in store8 store16 store32; do
    add "$s $OP" "$OP" \
      "(module (memory 1) (func (export \"f\") (i64.$s (i32.const 0) $E)))"
  done
done

# ---- [select] carries no result type on its Wax surface, so its arms must be
# pinned or an interposed width eraser cannot reach the flexible i64 tree beneath
# it. Wrap each width-sensitive tree in a same-type select, then erase. ----
for i in "${!INNER_EXPR[@]}"; do
  E="${INNER_EXPR[$i]}"; OP="${INNER_OP[$i]}"
  SEL="(select $E (i64.const 1) (i32.const 1))"
  add "wrap select $OP" "$OP" \
    "(module (func (export \"f\") (result i32) (i32.wrap_i64 $SEL)))"
  add "eqz select $OP" "$OP" \
    "(module (func (export \"f\") (result i32) (i64.eqz $SEL)))"
  add "drop select $OP" "$OP" \
    "(module (func (export \"f\") (drop $SEL)))"
done

# ---- Truncation source float width: the op's [as int] cast pins the result, not
# the source, so a bare float operand re-defaults. Values straddle the f32/f64
# and integer boundaries. ----
for op in trunc_f32_s trunc_f32_u trunc_f64_s trunc_f64_u \
          trunc_sat_f32_s trunc_sat_f64_u; do
  fw=f32; case "$op" in *f64*) fw=f64;; esac
  for res in i32 i64; do
    for v in 1.5 16777217 2147483648 4294967296; do
      add "$res.$op($fw.const $v)" "$res.$op" \
        "(module (func (export \"f\") (result $res) ($res.$op ($fw.const $v))))"
    done
  done
done

N=${#COMBOS[@]}

# Worker: round-trip each module wat -> wax -> wat; a crash/rejection on either
# leg is a finding, and the round-tripped wat must still contain the opcode.
worker() {
  local first="$1" last="$2" i label opcode body v out=""
  local p="$RESULTS/w$first"
  local wat="$p.wat" wax="$p.wax" back="$p.back.wat"
  ERRLOG="$p.err"
  for ((i = first; i <= last; i++)); do
    label="${COMBOS[$i]%%$'\t'*}"
    local rest="${COMBOS[$i]#*$'\t'}"
    opcode="${rest%%$'\t'*}"
    body="${rest#*$'\t'}"
    printf '%s\n' "$body" >"$wat"
    v="$(classify_wax -i wat -f wax "$wat" -o "$wax")"
    if [ "$v" != ok ]; then
      out+="$(finding DROPWIDTH HIGH "$label" "$v (wat->wax)" "$body")"$'\n'
      printf F >&2; continue
    fi
    v="$(classify_wax -i wax -f wat "$wax" -o "$back")"
    if [ "$v" != ok ]; then
      out+="$(finding DROPWIDTH HIGH "$label" "$v (wax->wat)" "$body")"$'\n'
      printf F >&2; continue
    fi
    if ! grep -qF "$opcode" "$back"; then
      local got
      got="$(grep -oE 'i(32|64)\.(div|rem|shr|shl|rotl|rotr|clz|ctz|popcnt)_?[su]?|i(32|64)\.trunc(_sat)?_f(32|64)_[su]' "$back" | tr '\n' ',')"
      out+="$(finding DROPWIDTH HIGH "$label" "width drift: $opcode gone (found: ${got:-none})" "$body")"$'\n'
      printf F >&2; continue
    fi
    printf . >&2
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$first"
}

echo "enumerating $N width-eraser combinations across $JOBS jobs (frozen wax)..." >&2
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
echo "=================== drop-width report ==================="
echo "combinations tested: $N"
echo "findings (crash / rejection / width drift): $n"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
fi
[ "$n" -gt 0 ] && exit 1
exit 0
