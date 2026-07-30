#!/usr/bin/env bash
#
# ref-width.sh
#
# The reference-side analogue of drop-width.sh, and the deterministic complement
# to the FAITHDRIFT round-trip leg: an enumerated sweep of the REFERENCE pins
# [From_wasm] still places by hand.
#
# Scalar widths are no longer pinned per site — the typer reconciles a recorded
# width and pins whatever would default wrong (see [Wax_lang.Typing.f]'s
# [~width_check]). References are the one class left outside that channel: their
# pins sit at five sites in [From_wasm] ([type_hole_src], [convert_src],
# [pin_hierarchy], [pin_descriptor]/[pin_descriptor_reftype], and the typed-[select]
# arm), each guarding a reference OPERATION whose Wax surface erases its operand's
# source hierarchy. Unpinned, the operand re-types in the target hierarchy on a
# re-parse and the operation is dropped or turned into a different one:
#
#   ref.i31            (_ as &i31)     absorbs a bare hole -> the op vanishes
#   i31.get_s/u        (_ as i32_s)    likewise
#   extern.convert_any (_ as &?extern) becomes ref.null extern / a ref.cast
#   ref.cast (ref extern)              becomes extern.convert_any (opcode family!)
#   ref.is_null        (!_)            becomes i32.eqz (opcode family!)
#   ref.eq             (_ == _)        becomes i32.eq  (opcode family!)
#
# Each is invisible to the validity oracles (both modules validate) and to a value
# comparison (these shapes live on the POLYMORPHIC dead-code stack, so nothing
# executes): the blast radius is decompiler FIDELITY, not runtime behaviour. That is
# what makes an enumerated sweep worth having — the nightly finds these by luck
# (`ref.as_non_null ; ref.cast (ref extern)` came back as `ref.as_non_null ;
# extern.convert_any` from a wasm-smith round trip), this checks every known shape
# on every run.
#
# The grid is OPS x CONTEXTS. The ops are read off the pin sites, so every site is
# covered; the contexts are the shapes the pins exist for (a bare hole, a
# select-of-holes, a hole through [ref.as_non_null], a hole behind an interposed
# zero-value statement — the [Stack.effective_backing] shapes — and a stranded
# leftover). Assertions are exact per cell rather than reusing the FAITHDRIFT
# leg's [opcode_sequence] normalisations: the confusable pairs those deliberately
# fold ([ref.cast] vs [extern.convert_any], [ref.is_null] vs [i32.eqz]) are exactly
# what must be told apart here, so each cell states both the opcode that must
# SURVIVE and the one that must be ABSENT. Both the default and the [--faithful]
# round trip are checked (the finding above fired on both).
#
# NOT asserted: the survival of a [ref.cast] into the any/eq/struct/array/i31/func
# hierarchies. A compiler-inserted type pin and a source [ref.cast] are
# indistinguishable without provenance, so cast fidelity is documented best-effort
# (docs/src/correspondence/round_trip.md) and the FAITHDRIFT leg drops [ref.cast]
# from its comparison for the same reason. The EXTERN-hierarchy casts are asserted
# because there the drift is an opcode-FAMILY change, not a lost pin.
#
# Deterministic, parallel, wax-only (no wasm-tools). Exits non-zero on any finding.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) * 4 ))}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT
freeze_wax "$RESULTS"

# Each cell is "label|flags|body|present|absent|modes": [flags] are extra wax flags
# (the descriptor cells need [-X custom-descriptors]), [body] is the function body,
# [present]/[absent] are comma-separated opcode lists the round-tripped wat must and
# must not contain, and [modes] selects which round trips assert them ("both", or
# "faithful" where the default path legitimately prunes the opcode — see the
# extern-cast note below). The fields are '|'-separated rather than tab-separated
# because TAB is IFS *whitespace*, which [read] collapses: an empty [flags] field
# would then shift every field after it.
CELLS=()
cell() { CELLS+=("$1|$2|$3|$4|$5|${6:-both}"); }

# ---- The reference operations, read off the pin sites. Each entry is
# "name|instrs|consumer|present|absent|operand"; [instrs] consumes the hole(s) the
# context leaves on the polymorphic stack, and [operand] is "ref" or "num" — the
# contexts that produce a REFERENCE operand (a [ref.as_non_null] chain) are skipped
# for an op that takes a numeric one, which would not be valid wasm. ----
declare -a OPS
op() { OPS+=("$1|$2|$3|$4|$5|${6:-ref}"); }

# [type_hole_src]: the op's surface [as] erases its operand's source hierarchy.
op "ref.i31"        "ref.i31"                    "drop" "ref.i31"            "" "num"
op "i31.get_s"      "i31.get_s"                  "drop" "i31.get_s"          "i31.get_u"
op "i31.get_u"      "i31.get_u"                  "drop" "i31.get_u"          "i31.get_s"
# [convert_src]: the cross-hierarchy converts, whose surface is a plain [as].
op "extern.convert_any" "extern.convert_any"     "drop" "extern.convert_any" "ref.cast"
op "any.convert_extern" "any.convert_extern"     "drop" "any.convert_extern" "ref.cast"
# [pin_hierarchy]: a [ref.cast] into the extern hierarchy shares its surface with
# [extern.convert_any], so an unpinned operand turns the cast into the convert.
op "ref.cast-extern"   "ref.cast (ref extern)"   "drop" "ref.cast"           "extern.convert_any"
op "ref.cast-noextern" "ref.cast (ref noextern)" "drop" "ref.cast"           "extern.convert_any"
# The two reference ops whose Wax surface is shared with a NUMERIC one.
op "ref.is_null"    "ref.is_null"                "drop" "ref.is_null"        "i32.eqz"
op "ref.test-i31"   "ref.test (ref null i31)"    "drop" "ref.test"           ""
op "ref.test-struct" "ref.test (ref \$s)"        "drop" "ref.test"           ""

# ---- The contexts: the shapes the pins exist for. [@OP@] is the operation,
# [@CONS@] its consumer. ----
declare -a CTX_NAME CTX_BODY
ctx() { CTX_NAME+=("$1"); CTX_BODY+=("$2"); }
# A bare hole off the polymorphic stack.
ctx "hole"       "unreachable @OP@ @CONS@"
# A select of holes: an untyped select re-parses type-adaptively, so it anchors
# nothing and the op's own pin has to carry the hierarchy.
ctx "select"     "unreachable i32.const 1 select @OP@ @CONS@"
# A hole through [ref.as_non_null] ([!] in Wax): the pin has to land on the hole
# itself, not around the [!] (there it would BE a cross-hierarchy convert).
ctx "nonnull"    "unreachable ref.as_non_null @OP@ @CONS@"
# An interposed zero-value statement: the [br_if] whose condition consumed the
# value just above it, so its own arity-0 entry backs nothing
# ([Stack.effective_backing] must see THROUGH it to the polymorphic bottom).
ctx "brif-stmt"  "(block unreachable i32.const 1 br_if 0 @OP@ @CONS@)"
# The same with an [atomic.fence], the other zero-value statement shape.
ctx "fence-stmt" "unreachable atomic.fence @OP@ @CONS@"
# A NUMERIC residual between the op's holes and the polymorphic bottom, behind
# statements: [Stack.effective_backing] must see THROUGH it (it cannot be the
# reference the hole reconnects to) and still reach the bottom, so the hole is
# pinned. The residual here is UNTAGGED — a method-form op inherits its receiver's
# flexibility, and the receiver is itself a hole — which is what made this shape a
# bottom-fuzz finding: read as a reference backing, it left the op unpinned and a
# dead [ref.eq] re-parsed as an [i32.eq].
ctx "num-resid-method" "unreachable f32.sqrt atomic.fence drop @OP@ @CONS@"
# The same with a tagged residual (a const) and with a load, whose result the
# method name states.
ctx "num-resid-const" "unreachable f32.const 1 atomic.fence drop @OP@ @CONS@"
ctx "num-resid-load" "unreachable f64.load atomic.fence drop @OP@ @CONS@"
# The residual behind the statement a DROP emits, with no fence.
ctx "num-resid-drop" "unreachable f32.sqrt drop @OP@ @CONS@"
# A V128 residual in the same position. [v128] carries no width tag (the tag lattice
# is scalar), so only its RECORD marks it as not-a-reference — a smith finding, where
# a dead vector op read as a backing left a [ref.is_null] unpinned and it re-parsed
# as an [i32.eqz]. Three producers: a vector op, a vector const, and a vector local.
ctx "v128-resid-op"    "unreachable i64x2.neg atomic.fence drop @OP@ @CONS@"
ctx "v128-resid-const" "unreachable v128.const i32x4 0 0 0 0 atomic.fence drop @OP@ @CONS@"
ctx "v128-resid-local" "unreachable local.get 0 atomic.fence drop @OP@ @CONS@"
# A SCALAR result of a SIMD op (an [i32] from a bitmask, a lane extraction), which
# must be recorded like any other numeric producer.
ctx "v128-resid-scalar" "unreachable local.get 0 i32x4.bitmask atomic.fence drop @OP@ @CONS@"
ctx "v128-resid-lane"   "unreachable local.get 0 i32x4.extract_lane 0 atomic.fence drop @OP@ @CONS@"
# A numeric CALL result as the residual: its type comes from the callee's signature,
# which the conversion records at the call's push site.
ctx "call-resid"        "unreachable call 0 atomic.fence drop @OP@ @CONS@"
ctx "call-ref-resid"    "unreachable local.get 1 call_ref \$ft atomic.fence drop @OP@ @CONS@"
# A signed packed aggregate read (an i32 whatever the field's width).
ctx "aggr-resid-signed" "unreachable local.get 2 struct.get_s \$s 1 atomic.fence drop @OP@ @CONS@"
# The op's own result stranded past a statement, so no consumer pops it
# ([Stack.run]'s leftover path rather than a direct pop).
ctx "strand"     "unreachable @OP@ nop @CONS@"

for oi in "${!OPS[@]}"; do
  IFS='|' read -r oname instrs cons present absent operand <<<"${OPS[$oi]}"
  for ci in "${!CTX_NAME[@]}"; do
    # [ref.as_non_null] yields a reference: an op taking a numeric operand cannot
    # follow it (the module would not be valid, which is a script bug, not a
    # finding).
    [ "${CTX_NAME[$ci]}" = nonnull ] && [ "$operand" = num ] && continue
    modes=both
    # A [ref.cast] to a NON-NULL extern type whose operand the pin has already
    # typed non-null ([(_ as &?extern)!]) is a provably redundant cast, and
    # [simplify] drops such a cast by design on the default path (it keeps it under
    # [--faithful], where the pass is off). Assert that cell on the faithful round
    # trip only; the [noextern] target differs from the pin's type, so it is not
    # redundant and is asserted on both.
    [ "$oname" = ref.cast-extern ] && [ "${CTX_NAME[$ci]}" = nonnull ] && modes=faithful
    body="${CTX_BODY[$ci]}"
    body="${body//@OP@/$instrs}"
    body="${body//@CONS@/$cons}"
    cell "$oname/${CTX_NAME[$ci]}" "" "$body" "$present" "$absent" "$modes"
  done
done

# ---- Shapes that do not fit the operand/consumer template, hand-written. ----

# The two converts sourced from a bare [null] rather than a hole: the inner
# any/extern cast must be kept, or the pair collapses to a plain [ref.null].
cell "extern.convert_any/null" "" \
  "unreachable ref.null any extern.convert_any drop" "extern.convert_any" "ref.cast"
cell "any.convert_extern/null" "" \
  "unreachable ref.null extern any.convert_extern drop" "any.convert_extern" "ref.cast"

# [ref.eq] takes TWO references, so it reads two holes (or a select and a hole).
cell "ref.eq/hole" "" "unreachable ref.eq drop" "ref.eq" "i32.eq"
cell "ref.eq/select" "" "unreachable i32.const 1 select ref.eq drop" "ref.eq" "i32.eq"
cell "ref.eq/brif-stmt" "" \
  "(block unreachable i32.const 1 br_if 0 ref.eq drop)" "ref.eq" "i32.eq"
# [ref.eq] with a NUMERIC residual between its holes and the polymorphic bottom —
# the bottom-fuzz finding itself (`f32.sqrt` is untagged, so the residual read as a
# reference backing and the op went unpinned, re-parsing as an [i32.eq]).
cell "ref.eq/num-resid-method" "" \
  "unreachable f32.sqrt atomic.fence drop ref.eq drop" "ref.eq" "i32.eq"
cell "ref.eq/num-resid-const" "" \
  "unreachable f32.const 1 atomic.fence drop ref.eq drop" "ref.eq" "i32.eq"
cell "ref.eq/num-resid-load" "" \
  "unreachable f64.load atomic.fence drop ref.eq drop" "ref.eq" "i32.eq"
cell "ref.eq/num-resid-drop" "" \
  "unreachable f32.sqrt drop ref.eq drop" "ref.eq" "i32.eq"
cell "ref.eq/v128-resid-op" "" \
  "unreachable i64x2.neg atomic.fence drop ref.eq drop" "ref.eq" "i32.eq"
cell "ref.eq/v128-resid-scalar" "" \
  "unreachable v128.const i32x4 0 0 0 0 i32x4.bitmask atomic.fence drop ref.eq drop" \
  "ref.eq" "i32.eq"

# The typed-[select] REFERENCE immediate: its arms carry no type on the Wax [?:]
# surface, so an arm must be pinned or the select re-parses as the numeric one and
# the following [ref.is_null] comes back as an [i32.eqz].
cell "typed-select/ref-immediate" "" \
  "unreachable i32.const 1 (select (result (ref null any))) ref.is_null drop" \
  "ref.is_null,select" "i32.eqz"

# [br_on_cast] / [br_on_cast_fail] carry their reftypes as immediates, so they are
# self-describing; included as controls that the surrounding recovery does not eat
# them in dead code.
cell "br_on_cast/hole" "" \
  "(block (result (ref null any)) unreachable br_on_cast 0 anyref anyref) drop" \
  "br_on_cast" ""
cell "br_on_cast_fail/hole" "" \
  "(block (result (ref null any)) unreachable br_on_cast_fail 0 anyref anyref) drop" \
  "br_on_cast_fail" ""

# A hole FORWARDED through [br_on_null] into a block with a reference result: the
# residual is arity >= 2 (the delivered values plus the fall-through ref), which a
# following convert cannot split, so [pin_forwarding_source] grounds the tested ref
# inside the branch. Unpinned, the convert gains a spurious second opcode.
cell "extern.convert_any/forwarded" "" \
  "(block (result (ref null any)) unreachable br_on_null 0 extern.convert_any drop unreachable) drop" \
  "extern.convert_any,br_on_null" "any.convert_extern"

# The descriptor ops ([pin_descriptor] / [pin_descriptor_reftype]), which need the
# custom-descriptors proposal and a describes/descriptor type prelude.
cell "ref.cast_desc_eq/hole" "-X custom-descriptors" \
  "unreachable ref.cast_desc_eq (ref null \$a) drop" "ref.cast_desc_eq" ""
cell "br_on_cast_desc_eq/hole" "-X custom-descriptors" \
  "(block (result (ref null \$a)) unreachable br_on_cast_desc_eq 0 (ref null any) (ref null \$a) unreachable) drop" \
  "br_on_cast_desc_eq" ""
cell "struct.new_default_desc/hole" "-X custom-descriptors" \
  "unreachable struct.new_default_desc \$a drop" "struct.new_default_desc" ""
cell "ref.get_desc/hole" "-X custom-descriptors" \
  "unreachable ref.get_desc \$a drop" "ref.get_desc" ""

N=${#CELLS[@]}

# The module a cell's body is dropped into: a struct type for the concrete-cast
# cells, a shared memory for the [atomic.fence] context, and (under the
# descriptors proposal) a described struct plus its descriptor.
module() {
  local flags="$1" body="$2"
  if [ -n "$flags" ]; then
    printf '(module\n  (rec\n    (type $a (sub (descriptor $b) (struct)))\n    (type $b (sub (describes $a) (struct))))\n  (memory 1 1 shared)\n  (func (export "f") %s))\n' "$body"
  else
    printf '(module\n  (type $s (sub (struct (field i32) (field i8))))\n  (type $ft (sub (func (result i64))))\n  (memory 1 1 shared)\n  (func $callee (result i64) (i64.const 1))\n  (func (export "f") (param $v v128) (param $fr (ref null $ft)) (param $sr (ref null $s)) %s))\n' "$body"
  fi
}

# Worker: for each cell, generate the module, check it (an invalid generation is a
# SCRIPT bug, reported as GENBUG, not a finding about wax), then round-trip it
# [wat -> wax -> wat] on the default AND the --faithful path, asserting the
# present/absent opcodes on each.
worker() {
  local first="$1" last="$2" i label flags body present absent v out=""
  local p="$RESULTS/w$first"
  local wat="$p.wat" wax="$p.wax" back="$p.back.wat"
  ERRLOG="$p.err"
  for ((i = first; i <= last; i++)); do
    IFS='|' read -r label flags body present absent modes <<<"${CELLS[$i]}"
    module "$flags" "$body" >"$wat"
    # A subcommand's own flags come AFTER it ([wax check -X …]); the convert calls
    # below take theirs on the default command, where they precede the input.
    # shellcheck disable=SC2086
    if [ "$(classify_wax check $flags "$wat")" != ok ]; then
      out+="$(finding GENBUG REVIEW "$label" "generated module is not valid wasm" "$body")"$'\n'
      printf G >&2
      continue
    fi
    local mode ok=1
    for mode in "" "--faithful"; do
      # A cell may assert its opcodes on the faithful round trip only.
      [ "$modes" = faithful ] && [ -z "$mode" ] && continue
      # shellcheck disable=SC2086
      v="$(classify_wax $flags -i wat -f wax $mode "$wat" -o "$wax")"
      if [ "$v" != ok ]; then
        out+="$(finding REFDRIFT HIGH "$label" "$v (wat->wax${mode:+ $mode})" "$body")"$'\n'
        ok=0
        continue
      fi
      # shellcheck disable=SC2086
      v="$(classify_wax $flags -i wax -f wat "$wax" -o "$back")"
      if [ "$v" != ok ]; then
        out+="$(finding REFDRIFT HIGH "$label" "$v (wax->wat${mode:+ $mode})" "$body")"$'\n'
        ok=0
        continue
      fi
      local op
      IFS=, read -ra want <<<"$present"
      for op in "${want[@]}"; do
        [ -n "$op" ] || continue
        if ! grep -qF "$op" "$back"; then
          out+="$(finding REFDRIFT HIGH "$label" \
            "${mode:-default}: $op did not survive the round trip (got: $(grep -oE 'ref\.[a-z_]+|extern\.convert_any|any\.convert_extern|i31\.get_[su]|i32\.eqz|i32\.eq|struct\.new[a-z_]*|select' "$back" | sort -u | tr '\n' ',' ))" \
            "$body")"$'\n'
          ok=0
        fi
      done
      IFS=, read -ra nope <<<"$absent"
      for op in "${nope[@]}"; do
        [ -n "$op" ] || continue
        if grep -qF "$op" "$back"; then
          out+="$(finding REFDRIFT HIGH "$label" \
            "${mode:-default}: $op appeared — the operation drifted into its confusable twin" \
            "$body")"$'\n'
          ok=0
        fi
      done
    done
    if [ "$ok" = 1 ]; then printf . >&2; else printf F >&2; fi
  done
  [ -n "$out" ] && printf '%s' "$out" >"$RESULTS/$first"
}

echo "enumerating $N reference-pin cells across $JOBS jobs (frozen wax)..." >&2
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
high=$(grep -c $'\tHIGH\t' "$REPORT" 2>/dev/null); high=${high:-0}
echo "=================== ref-width report ==================="
echo "cells tested: $N"
echo "findings: $n  (HIGH: $high)"
if [ "$n" -gt 0 ]; then
  echo
  cut -f2,3,4,5 "$REPORT" | sort -u | sed 's/^/  /'
fi
[ "$high" -gt 0 ] && exit 1
exit 0
