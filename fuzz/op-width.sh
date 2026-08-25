#!/usr/bin/env bash
#
# op-width.sh
#
# The width-drift grid DERIVED FROM THE INSTRUCTION TABLE, rather than from a
# hand list. Every prior grid in the family (drop-width, adaptive-width,
# atomic-width, pin-reach) enumerates the shapes its author thought of — and
# the founding finding of each was an opcode family nobody's hand list held
# (atomics, most recently). This grid closes that meta-hole: the operation
# list is the WAT lexer's own keyword table ([Wax_wasm.Lexer.keywords], via
# the [dump_mnemonics] developer exe), so a mnemonic the toolchain learns to
# parse is in the grid the same day, with no list to forget to update.
#
# Each instruction mnemonic gets an INSTANTIATION (its immediates filled from a
# canned module template: types $s/$a/$ap/$ft/$ct, memory, table $tb, global
# $g, locals, tag $t, segments $d/$e) and is placed on the DEAD-CODE stack
# (after [return], where every operand is a hole and nothing but the printed
# form states a width) under every eraser context in CTX below — the width
# erasers of drop-width.sh plus the reference-op and select shapes. A cell the
# validator rejects is skipped, not counted: the cross-product over-generates
# and validity filters it, which is what keeps the instantiation rules coarse.
# Each valid cell must round-trip wat -> wax -> wat in BOTH modes (default and
# --faithful) with the producer's opcode — and the context's load-bearing
# opcode — surviving word-anchored.
#
# Two RATCHETS keep the derivation honest, both against the checked-in
# acknowledgment file [op-width.acknowledged], strict in BOTH directions (a
# stale acknowledgment fails like a missing one, as with the parser-message
# overrides):
#   no-rule <kw>        — a keyword with no instantiation rule (structural
#                         words, block openers, wast script words). A NEW
#                         mnemonic entering the lexer fails here until someone
#                         writes it a rule or consciously acknowledges it.
#   no-valid-cell <op>  — an instantiated op none of whose cells validated
#                         (e.g. a feature-gated instruction the plain template
#                         cannot host). Visible rather than silently untested.
#
# EXEMPT (see [exempt] below): the documented shared spellings — a fused
# narrow/32-bit load widened by the matching extend IS the wider load, so the
# round trip may normalize the pair (CLAUDE.md's --faithful residuals) — plus
# the classes calibrated below it. Everything else must come back opcode-for-
# opcode.
#
# Blast radius: dead-code FIDELITY (both modules validate; only the opcode
# comparison sees a drift), plus a refusal to convert where a repair cannot
# reach (the pin-reach class). Calibration against the binary before the
# atomic-RMW fix (83357064e9, the parent of 484ff81b44): 42 findings — every
# narrow i64 atomic RMW under [wrap], both modes — and 0 on the fixed binary;
# the derivation rediscovers atomic-width.sh's founding class with no atomic
# mnemonic hand-listed anywhere in this file. Deterministic, parallel,
# wax-only. Like every guard here it tests the binaries [_build] currently
# holds and never builds them, so run [dune build] first (check.sh builds
# dump_mnemonics too).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export LC_ALL=C

DUMP="${DUMP:-$ROOT/_build/default/src/bin/dump_mnemonics.exe}"
ACK="$ROOT/fuzz/op-width.acknowledged"
[ -x "$DUMP" ] || { echo "op-width: $DUMP not built (dune build); skipping" >&2; exit 2; }

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 2 ))}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# ---- The module template every cell instantiates. ----
# $sp/$ap carry a PACKED field/element (for the _s/_u accessors), $s/$a an i64
# one (the drift-prone width); $ft returns an i64 for the same reason.
template() { # $1 = the instruction lines
  cat <<EOF
(module
  (type \$ft (func (result i64)))
  (type \$ct (cont \$ft))
  (type \$s (struct (field (mut i64))))
  (type \$sp (struct (field (mut i8))))
  (type \$a (array (mut i64)))
  (type \$ap (array (mut i8)))
  (type \$ar (array (mut funcref)))
  (rec
    (type \$fts (func (param (ref null \$cts)) (result i64)))
    (type \$cts (cont \$fts)))
  (memory 1 1 shared)
  (table \$tb 1 1 funcref)
  (global \$g (mut i64) (i64.const 0))
  (tag \$t (param i64))
  (tag \$ts (result i64))
  (elem \$e func \$f)
  (data \$d "abcd")
  (func \$f (result i64) (i64.const 1))
  (type \$ft0 (func))
  (func \$f0)
  (func (local \$l64 i64) (local \$lv v128)
    return
    $1))
EOF
}

# ---- Instantiate one mnemonic: fill its immediates from the template. ----
# Prints the instruction (possibly multi-token) or fails = no rule. Coarse on
# purpose: an instantiation whose cell can never validate is caught by the
# no-valid-cell ratchet, not silently dropped here.
instantiate() {
  local op="$1"
  case "$op" in
    # Not single instructions: structural words, block openers (pin-reach.sh
    # owns block shapes), wast script words, condition/hint words.
    i8x16.shuffle) echo "i8x16.shuffle 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0" ;;
    v128.const) echo "v128.const i64x2 1 1" ;;
    i32.const | i64.const) echo "$op 1" ;;
    f32.const | f64.const) echo "$op 1.5" ;;
    *.extract_lane | *.extract_lane_s | *.extract_lane_u | *.replace_lane) echo "$op 0" ;;
    v128.load*_lane | v128.store*_lane) echo "$op 0" ;;
    local.get | local.set | local.tee) echo "$op \$l64" ;;
    global.get | global.set) echo "$op \$g" ;;
    call | ref.func) echo "$op \$f" ;;
    call_ref) echo "call_ref \$ft" ;;
    call_indirect) echo "call_indirect \$tb (type \$ft)" ;;
    # A tail call must match the CALLER's (empty) signature, so it targets the
    # void \$f0/\$ft0, not the i64-returning \$f/\$ft.
    return_call) echo "return_call \$f0" ;;
    return_call_ref) echo "return_call_ref \$ft0" ;;
    return_call_indirect) echo "return_call_indirect \$tb (type \$ft0)" ;;
    br | br_if | br_on_null | br_on_non_null) echo "$op 0" ;;
    br_table) echo "br_table 0 0" ;;
    br_on_cast | br_on_cast_fail) echo "$op 0 anyref (ref null \$a)" ;;
    br_on_cast_desc_eq | br_on_cast_desc_eq_fail) echo "$op 0 (ref null \$s)" ;;
    ref.null) echo "ref.null extern" ;;
    ref.test | ref.cast) echo "$op (ref null \$a)" ;;
    ref.cast_desc_eq) echo "ref.cast_desc_eq (ref null \$s)" ;;
    struct.new | struct.new_default | struct.new_desc | struct.new_default_desc)
      echo "$op \$s" ;;
    struct.get | struct.set) echo "$op \$s 0" ;;
    struct.get_s | struct.get_u) echo "$op \$sp 0" ;;
    array.len) echo "array.len" ;;
    array.new | array.new_default | array.get | array.set | array.fill)
      echo "$op \$a" ;;
    array.get_s | array.get_u) echo "$op \$ap" ;;
    array.new_fixed) echo "array.new_fixed \$a 0" ;;
    array.new_data | array.init_data) echo "$op \$ap \$d" ;;
    array.new_elem | array.init_elem) echo "$op \$ar \$e" ;;
    array.copy) echo "array.copy \$a \$a" ;;
    memory.init) echo "memory.init \$d" ;;
    data.drop) echo "data.drop \$d" ;;
    table.init) echo "table.init \$tb \$e" ;;
    elem.drop) echo "elem.drop \$e" ;;
    table.copy) echo "table.copy \$tb \$tb" ;;
    table.get | table.set | table.size | table.grow | table.fill) echo "$op \$tb" ;;
    throw | suspend) echo "$op \$t" ;;
    cont.new | resume | resume_throw_ref) echo "$op \$ct" ;;
    cont.bind) echo "cont.bind \$ct \$ct" ;;
    resume_throw) echo "resume_throw \$ct \$t" ;;
    # [switch]'s continuation must take a continuation as its LAST parameter
    # (where the switched-away one arrives), hence the recursive \$cts, and its
    # tag carries result types only.
    switch) echo "switch \$cts \$ts" ;;
    # The bare families: numeric/float ops, loads/stores, atomics, SIMD plain
    # ops, the i31/extern/any conversions, select, drop, simple refs, fences.
    i32.* | i64.* | f32.* | f64.* | v128.* | i8x16.* | i16x8.* | i32x4.* | i64x2.* | f32x4.* | f64x2.*)
      echo "$op" ;;
    memory.atomic.* | atomic.fence | memory.size | memory.grow | memory.copy | memory.fill)
      echo "$op" ;;
    i31.get_s | i31.get_u | ref.i31 | ref.eq | ref.is_null | ref.as_non_null)
      echo "$op" ;;
    any.convert_extern | extern.convert_any | ref.get_desc) echo "$op" ;;
    select | drop | nop | unreachable | return | throw_ref) echo "$op" ;;
    *) return 1 ;;
  esac
}

# ---- The eraser contexts a produced value can land in. ----
# Each context's LOAD-BEARING opcode (checked to survive too, empty = none) is
# the first field; the code the second. The value-erasing shapes of
# drop-width.sh, both int widths of eqz, the truncation/precision erasers, the
# narrow-store value position, the reference ops whose Wax surface erases the
# operand's family, an untyped select arm, and the bare-leftover shape (no
# consumer at all — the [Stack.run] pin_stranded dimension).
declare -a CTX_NAME CTX_KEY CTX_CODE
ctx() { CTX_NAME+=("$1"); CTX_KEY+=("$2"); CTX_CODE+=("$3"); }
ctx "leftover" ""              ""
ctx "bare"     ""              "drop"
ctx "wrap"     "i32.wrap_i64"  $'i32.wrap_i64\n    drop'
ctx "extd_u"   "i64.extend_i32_u" $'i64.extend_i32_u\n    drop'
ctx "eqz32"    "i32.eqz"       $'i32.eqz\n    drop'
ctx "eqz64"    "i64.eqz"       $'i64.eqz\n    drop'
ctx "trunc32"  "i32.trunc_f32_s" $'i32.trunc_f32_s\n    drop'
ctx "trunc64"  "i32.trunc_f64_s" $'i32.trunc_f64_s\n    drop'
ctx "demote"   "f32.demote_f64" $'f32.demote_f64\n    drop'
ctx "promote"  "f64.promote_f32" $'f64.promote_f32\n    drop'
ctx "store32"  "i64.store32"   "i64.store32"
ctx "store16"  "i32.store16"   "i32.store16"
ctx "isnull"   "ref.is_null"   $'ref.is_null\n    drop'
ctx "select"   "select"        $'i32.const 0\n    select\n    drop'

# ---- Shared spellings the round trip is documented to normalize. ----
# op/ctx/mode (mode = default | faithful), checked per mode so a default-path
# recovery's exemption still asserts --faithful keeps the pair. The classes:
# a fused load + matching zero-extend IS the wider load (same bytes, alignment,
# extension — the atomic-width exemptions plus their plain-load siblings);
# [t.eq ; i32.eqz] fuses to [t.ne] on the default path only (the [--faithful]
# gate's founding example); and a [ref.cast] over a dead-code HOLE cannot
# survive by construction — [_ as &t] on a hole IS the typed-hole ascription
# spelling, not a cast (see CLAUDE.md's --debug row), so the opcode is dropped
# in both modes.
exempt() {
  case "$1/$2/$3" in
    i32.load/extd_u/* | i32.load8_u/extd_u/* | i32.load16_u/extd_u/* \
    | i32.atomic.load/extd_u/* | i32.atomic.load8_u/extd_u/* \
    | i32.atomic.load16_u/extd_u/*) return 0 ;;
    i32.eq/eqz32/default | i64.eq/eqz32/default | f32.eq/eqz32/default \
    | f64.eq/eqz32/default) return 0 ;;
    ref.cast/bare/* | ref.cast/isnull/*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- Enumerate: keywords -> rules -> cells; collect the no-rule list. ----
mapfile -t KEYWORDS < <("$DUMP")
COMBOS=()
: >"$RESULTS/no-rule"
declare -A HAS_RULE
for kw in "${KEYWORDS[@]}"; do
  if code="$(instantiate "$kw")"; then
    HAS_RULE[$kw]=1
    for k in "${!CTX_NAME[@]}"; do
      COMBOS+=("$kw"$'\t'"$k"$'\t'"$code")
    done
  else
    echo "no-rule $kw" >>"$RESULTS/no-rule"
  fi
done
N=${#COMBOS[@]}

worker() {
  local first="$1" last="$2" i op code cname ckey ccode v mode m out="" skipped=0
  local p="$RESULTS/w$first"
  local wat="$p.wat" wax="$p.wax" back="$p.back.wat"
  ERRLOG="$p.err"
  local k rest
  for ((i = first; i <= last; i++)); do
    op="${COMBOS[$i]%%$'\t'*}"
    rest="${COMBOS[$i]#*$'\t'}"
    k="${rest%%$'\t'*}"
    code="${rest#*$'\t'}"
    cname="${CTX_NAME[$k]}" ckey="${CTX_KEY[$k]}" ccode="${CTX_CODE[$k]}"
    template "$code"$'\n    '"$ccode" >"$wat"
    if [ "$(classify_wax check "$wat")" != ok ]; then
      skipped=$((skipped + 1)); printf s >&2
      echo "$op" >>"$p.invalid"
      continue
    fi
    echo "$op" >>"$p.valid"
    for mode in "" "--faithful"; do
      v="$(classify_wax -i wat -f wax $mode --error-format short "$wat" -o "$wax")"
      if [ "$v" != ok ]; then
        out+="$(finding OPWIDTH HIGH "$op/$cname" \
          "${mode:-default}: $v (wat->wax): $(head -1 "$ERRLOG")" \
          "wax -i wat -f wax $mode over: $code / $cname")"$'\n'
        printf F >&2; continue
      fi
      v="$(classify_wax -i wax -f wat "$wax" -o "$back")"
      if [ "$v" != ok ]; then
        out+="$(finding OPWIDTH HIGH "$op/$cname" \
          "${mode:-default}: $v (wax->wat): $(head -1 "$ERRLOG")" "$op")"$'\n'
        printf F >&2; continue
      fi
      # A conversion crash/rejection is a finding even on an exempted pair;
      # only the opcode-survival comparison is waived for those.
      if [ -n "$mode" ]; then m=faithful; else m=default; fi
      exempt "$op" "$cname" "$m" && continue
      # Word-boundary anchored: [i32.load] must not be satisfied by
      # [i32.load8_u]; same for the context's load-bearing opcode.
      if ! grep -qE "${op//./\\.}([^0-9a-z_.]|\$)" "$back"; then
        out+="$(finding OPWIDTH HIGH "$op/$cname" \
          "${mode:-default}: producer opcode drifted" "$op")"$'\n'
        printf F >&2; continue
      fi
      if [ -n "$ckey" ] && ! grep -qE "${ckey//./\\.}([^0-9a-z_.]|\$)" "$back"; then
        out+="$(finding OPWIDTH HIGH "$op/$cname" \
          "${mode:-default}: context opcode ($ckey) drifted" "$op")"$'\n'
        printf F >&2; continue
      fi
    done
    printf . >&2
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$first"
  [ "$skipped" -gt 0 ] && printf '%s\n' "$skipped" >"$RESULTS/skip.$first"
  return 0
}

echo "op-width: $N table-derived cells across $JOBS jobs (frozen wax)..." >&2
chunk=$(((N + JOBS - 1) / JOBS))
for ((w = 0; w < JOBS; w++)); do
  first=$((w * chunk))
  [ "$first" -ge "$N" ] && break
  last=$((first + chunk - 1)); [ "$last" -ge "$N" ] && last=$((N - 1))
  worker "$first" "$last" &
done
wait
echo >&2

# ---- The no-valid-cell ratchet: an op every cell of which was skipped. ----
sort -u "$RESULTS"/w*.valid >"$RESULTS/valid-ops" 2>/dev/null || : >"$RESULTS/valid-ops"
: >"$RESULTS/no-valid-cell"
for kw in "${!HAS_RULE[@]}"; do
  grep -qxF "$kw" "$RESULTS/valid-ops" || echo "no-valid-cell $kw" >>"$RESULTS/no-valid-cell"
done

REPORT="$RESULTS/report"
cat "$RESULTS"/[0-9]* 2>/dev/null >"$REPORT"
n=$(grep -c '^FINDING' "$REPORT" 2>/dev/null); n=${n:-0}
skipped=$(cat "$RESULTS"/skip.* 2>/dev/null | paste -sd+ | bc 2>/dev/null); skipped=${skipped:-0}

# ---- Acknowledgment diff, strict both ways. ----
sort "$RESULTS/no-rule" "$RESULTS/no-valid-cell" >"$RESULTS/unhandled"
grep -v '^#' "$ACK" 2>/dev/null | grep -v '^[[:space:]]*$' | sort >"$RESULTS/acked" || : >"$RESULTS/acked"
new_unacked="$(comm -13 "$RESULTS/acked" "$RESULTS/unhandled")"
stale_acked="$(comm -23 "$RESULTS/acked" "$RESULTS/unhandled")"

echo "=================== op-width report ==================="
echo "keywords: ${#KEYWORDS[@]}  cells: $N  tested: $((N - skipped))  (skipped as invalid: $skipped)"
h=$(grep -c $'\tHIGH\t' "$REPORT" 2>/dev/null); h=${h:-0}
echo "findings: $n  (HIGH: $h)"
fail=0
if [ "$n" -gt 0 ]; then cat "$REPORT"; fail=1; fi
if [ -n "$new_unacked" ]; then
  echo "UNACKNOWLEDGED keywords (new mnemonic? write it an instantiation rule"
  echo "in op-width.sh, or acknowledge it in op-width.acknowledged with why):"
  echo "$new_unacked"
  fail=1
fi
if [ -n "$stale_acked" ]; then
  echo "STALE acknowledgments (now handled — remove from op-width.acknowledged):"
  echo "$stale_acked"
  fail=1
fi
exit "$fail"
