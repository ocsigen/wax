# fold-gen.awk — generate a WAT module densely packed with the instruction
# variety the folding pass (lib-wasm/folding.ml) must reason about, to fuzz
# fold/unfold. -v seed=N is the only input.
#
# Why a dedicated generator (and not just the corpus): folding computes, for
# every instruction, its (inputs, outputs) arity — a ~170-line match over the
# whole opcode set (folding.ml `arity`) plus the index-resolution helpers
# (type/function/global/tag/local/label). The corpus reaches barely half of it,
# because the arms that stay dark are the ones the corpus's wat files rarely
# contain: stack switching (cont.*/resume*/switch/suspend), GC struct/array,
# the SIMD and atomic families, 128-bit ops, and the by-name resolution of a
# name declared with a different arity in each branch of a conditional.
#
# Two properties of the fold pass shape the output:
#   * it runs on UNVALIDATED input (an unvalidated wat->wat, or a trusted
#     wasm->wat), so the module need not type-check — only parse — and stack
#     imbalance is deliberate: it drives fold_instr's operand-shortfall /
#     leftover paths (push_back / tentative_args), themselves dark arms.
#   * it aborts only on an unbound / wrong-kind INDEX or an unbound LABEL. So
#     the preamble below populates every index space, and branches only ever
#     target a label that is in scope; everything else is free to be nonsense.
#
# The paired driver is fold-fuzz.sh, whose confluence oracle checks that
# unfold(fold(x)) == unfold(x) (folding must not perturb the instruction
# stream). Descriptor-proposal ops (struct.new_desc, ref.get_desc, ...) need a
# feature flag to parse and are left out; everything here parses with defaults.

BEGIN {
  srand(seed)
  uid = 0

  # Block types used on block-family instructions and by `call_indirect`.
  nbt = split(", (result i32), (param i32), (param i32) (result i32), (type $ft1)", BT, ",")

  # Leaf (non-branch, non-block) instructions. Every index is one the preamble
  # binds; folding resolves each without aborting. Grouped by the `arity` arm
  # they light up; stack effect is irrelevant to folding.
  nleaf = split( \
    "i32.const 7|i64.const 8|f32.const 1.5|f64.const 2.5|i32.add|i64.sub|f64.mul|" \
    "i32.eqz|i32.eq|f64.lt|i32.clz|f32.abs|" \
    "i32.wrap_i64|i64.extend_i32_s|i64.extend_i32_u|f32.demote_f64|f64.promote_f32|" \
    "i32.trunc_f64_s|i64.trunc_sat_f32_u|f64.convert_i32_s|" \
    "i64.add128|i64.sub128|i64.mul_wide_s|i64.mul_wide_u|" \
    "drop|select|select (result i32)|nop|unreachable|return|" \
    "local.get 0|local.set 0|local.tee 1|local.get 2|" \
    "global.get $g0|global.set $g1|global.get $gf|global.set $gf|" \
    "i32.load|i64.load offset=8|i32.store|f64.store align=4|i32.load8_u offset=1|" \
    "memory.size|memory.grow|memory.fill|memory.copy|memory.init 0|data.drop 0|" \
    "table.get $tab|table.set $tab|table.size $tab|table.grow $tab|table.fill $tab|" \
    "table.copy $tab $tab|table.init $tab 0|elem.drop 0|" \
    "ref.null func|ref.null $st|ref.func $h0|ref.func $h1|ref.is_null|ref.as_non_null|" \
    "ref.eq|ref.i31|i31.get_s|i31.get_u|ref.test (ref null $st)|ref.cast (ref $st)|" \
    "ref.test (ref $at)|extern.convert_any|any.convert_extern|" \
    "struct.new $st|struct.new_default $st|struct.get $st 0|struct.get_s $st 0|" \
    "struct.set $st 1|" \
    "array.new $at|array.new_default $at|array.new_fixed $at 3|array.get $at|" \
    "array.get_s $at|array.set $at|array.len|array.fill $at|array.copy $at $at|" \
    "array.new_elem $at 0|array.new_data $at 0|array.init_data $at 0|array.init_elem $at 0|" \
    "call $h1|call 0|call_ref $ft1|call_indirect (type $ft1)|call_indirect $tab (type $ft2)|" \
    "return_call $h0|return_call_ref $ft1|return_call_indirect (type $ft1)|" \
    "throw $e1|throw_ref|" \
    "cont.new $ct|cont.bind $ct $ct|suspend $e1|resume $ct|resume $ct (on $e1 switch)|" \
    "resume_throw $ct $e1|resume_throw_ref $ct|switch $ct $e0|" \
    "i32.atomic.load|i32.atomic.store|i32.atomic.rmw.add|i32.atomic.rmw8.cmpxchg_u|" \
    "memory.atomic.wait32|memory.atomic.notify|atomic.fence|" \
    "v128.const i32x4 0 0 0 0|i32x4.add|i8x16.sub|f64x2.mul|i32x4.splat|f32x4.splat|" \
    "v128.load|v128.store|v128.load8_splat|v128.load8_lane 0|v128.store8_lane 0|" \
    "i32x4.extract_lane 0|i8x16.extract_lane_s 0|i32x4.replace_lane 0|" \
    "i8x16.shuffle 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15|i8x16.swizzle|v128.bitselect|" \
    "i32x4.all_true|v128.any_true|i8x16.bitmask|i32x4.shl|v128.not|v128.and|" \
    "i32x4.dot_i16x8_s|i16x8.extmul_low_i8x16_s|f32x4.relaxed_madd", \
    LEAF, "|")

  print "(module"
  print "  (rec"
  print "    (type $ft0 (func))"
  print "    (type $ft1 (func (param i32) (result i32)))"
  print "    (type $ft2 (func (param i32 i64) (result i32 i32)))"
  print "    (type $st (struct (field i32) (field (mut i64))))"
  print "    (type $at (array (mut i32)))"
  print "    (type $ct (cont $ft1)))"
  print "  (tag $e0)"
  print "  (tag $e1 (param i32))"
  print "  (memory 1)"
  print "  (table $tab 8 funcref)"
  print "  (global $g0 i32 (i32.const 0))"
  print "  (global $g1 (mut i64) (i64.const 0))"
  print "  (global $gf (mut f64) (f64.const 0))"
  print "  (data \"abcd\")"
  print "  (elem declare func $h0 $h1)"
  print "  (func $h0)"
  print "  (func $h1 (param i32) (result i32) (local.get 0))"

  # Half the modules declare a function under a conditional with a DIFFERENT
  # arity in each branch and then call it by name from an unconditional body:
  # this is the only thing that exercises folding's by-name resolution across
  # mutually-exclusive branch assumptions (Tbl.resolve's multi-declaration arm).
  use_dup = (rand() < 0.5)
  if (use_dup) {
    print "  (@if $native"
    print "    (@then (func $dup (param i32) (result i32) (local.get 0)))"
    print "    (@else (func $dup)))"
  }

  nf = int(rand() * 3) + 1
  for (k = 0; k < nf; k++) emit_func(k)
  print ")"
}

# A fuzz function: locals of every value type, then a flat, deliberately
# unbalanced instruction stream for the fold pass to nest.
function emit_func(k,   bt) {
  bt = pick(BT, nbt)
  print "  (func $f" k " " bt
  print "    (local i32 i64 f32 f64 v128 funcref externref)"
  budget = int(rand() * 24) + 10
  depthleft = 4
  body("")
  if (use_dup) print "    call $dup"
  print "  )"
}

function pick(arr, n) { return arr[int(rand() * n) + 1] }

# Emit a sequence of instructions whose in-scope labels are `labelstr` (a
# space-separated list of label ids, innermost last).
function body(labelstr,   i, n) {
  n = int(rand() * 4) + 2
  for (i = 0; i < n; i++) {
    if (budget <= 0) return
    budget--
    emit_one(labelstr)
  }
}

function emit_one(labelstr,   r, lab, bt, kind) {
  r = int(rand() * 100)
  if (r < 22 && depthleft > 0) {          # a block-family (structured) instruction
    depthleft--
    lab = "$L" uid; uid++
    bt = pick(BT, nbt)
    kind = int(rand() * 5)
    if (kind == 0) { print "    block " lab " " bt; body(labelstr " " lab); print "    end" }
    else if (kind == 1) { print "    loop " lab " " bt; body(labelstr " " lab); print "    end" }
    else if (kind == 2) {
      print "    if " lab " " bt; body(labelstr " " lab)
      print "    else"; body(labelstr " " lab); print "    end"
    } else if (kind == 3) {
      # try_table: catch handlers reference a label (folding ignores catch
      # labels but folds the block body); target an enclosing label if any.
      print "    try_table " lab " " bt " (catch $e0 " lab ") (catch_all " lab ")"
      body(labelstr " " lab); print "    end"
    } else {
      print "    try " lab " " bt; body(labelstr " " lab)
      print "    catch $e1"; body(labelstr " " lab)
      print "    catch_all"; body(labelstr " " lab); print "    end"
    }
    depthleft++
  } else if (r < 38) {
    branch(labelstr)
  } else {
    print "    " pick(LEAF, nleaf)
  }
}

# A branch targeting a random in-scope label (folding resolves the label, so it
# must be in scope); falls back to a leaf when no label is in scope.
function branch(labelstr,   arr, m, lab, r) {
  m = split(labelstr, arr, " ")
  if (m == 0) { print "    " pick(LEAF, nleaf); return }
  lab = arr[int(rand() * m) + 1]
  r = int(rand() * 7)
  if (r == 0) print "    br " lab
  else if (r == 1) print "    br_if " lab
  else if (r == 2) print "    br_table " lab " " lab " " lab
  else if (r == 3) print "    br_on_null " lab
  else if (r == 4) print "    br_on_non_null " lab
  else if (r == 5) print "    br_on_cast " lab " (ref null $st) (ref $st)"
  else print "    br_on_cast_fail " lab " (ref null $st) (ref $st)"
}
