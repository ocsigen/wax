In dead code (after `unreachable`) a numeric binop/select pops holes off an empty
stack. Those holes must keep the opcode's width across a Wasm->Wax->Wasm round
trip: without a pin they re-parse as the i32 default, so `i64.add` would come back
as `i32.add`. `from_wasm` pins exactly one anchor-free hole (or, for a comparison
/ typed select, one arm) with the opcode's scalar type, but only when needed. A
non-i32 width is pinned as `(_ as t)`; i32 is the re-parse default, so it gets no
pin (no noise); an anchor operand (a local, a call result) fixes the width by
itself, so its fellow holes stay bare; and a flexible literal (`i64.const 5`) is
grounded by the single pin, not pinned itself.

  $ cat > m.wat <<'WAT'
  > (module
  >   (func $i32_add unreachable i32.add drop)
  >   (func $i64_add unreachable i64.add drop)
  >   (func $f32_add unreachable f32.add drop)
  >   (func $f64_add unreachable f64.add drop)
  >   (func $i64_shr unreachable i64.shr_u drop)
  >   (func $i32_shl unreachable i32.shl drop)
  >   (func $i64_cmp unreachable i64.lt_s drop)
  >   (func $f64_cmp unreachable f64.gt drop)
  >   (func $i32_cmp unreachable i32.eq drop)
  >   (func $lit_flex unreachable i64.const 5 i64.add drop)
  >   (func $anchor (param i64) unreachable local.get 0 i64.add drop)
  >   (func $sel_i64 (result i64) unreachable (select (result i64)))
  >   (func $sel_f32 (result f32) unreachable (select (result f32)))
  >   (func $sel_i32 (result i32) unreachable (select (result i32))))
  > WAT

The Wax carries a width pin only where re-parse would otherwise lose it (never on
an i32 op or an anchored operand):

  $ wax -i wat -f wax m.wat
  fn i32_add() {
      unreachable;
      _ = _ + _;
  }
  fn i64_add() {
      unreachable;
      _ = _ as i64 + _;
  }
  fn f32_add() {
      unreachable;
      _ = _ as f32 + _;
  }
  fn f64_add() {
      unreachable;
      _ = _ as f64 + _;
  }
  fn i64_shr() {
      unreachable;
      _ = _ as i64 >>u _;
  }
  fn i32_shl() {
      unreachable;
      _ = _ << _;
  }
  fn i64_cmp() {
      unreachable;
      _ = _ as i64 <s _;
  }
  fn f64_cmp() {
      unreachable;
      _ = _ as f64 > _;
  }
  fn i32_cmp() {
      unreachable;
      _ = _ == _;
  }
  fn lit_flex() {
      unreachable;
      _ = _ as i64 + 5;
  }
  fn anchor(x: i64) {
      unreachable;
      _ = _ + x;
  }
  fn sel_i64() -> i64 {
      unreachable;
      _?_ as i64:_;
  }
  fn sel_f32() -> f32 {
      unreachable;
      _?_ as f32:_;
  }
  fn sel_i32() -> i32 {
      unreachable;
      _?_:_;
  }

Round-tripping back to Wasm recovers every opcode at its original width:

  $ wax -i wat -f wax m.wat -o m.wax && wax -i wax -f wat m.wax
  (func $i32_add (unreachable) (drop (i32.add)))
  (func $i64_add (unreachable) (drop (i64.add)))
  (func $f32_add (unreachable) (drop (f32.add)))
  (func $f64_add (unreachable) (drop (f64.add)))
  (func $i64_shr (unreachable) (drop (i64.shr_u)))
  (func $i32_shl (unreachable) (drop (i32.shl)))
  (func $i64_cmp (unreachable) (drop (i64.lt_s)))
  (func $f64_cmp (unreachable) (drop (f64.gt)))
  (func $i32_cmp (unreachable) (drop (i32.eq)))
  (func $lit_flex (unreachable) (drop (i64.add (i64.const 5))))
  (func $anchor (param $x i64) (unreachable) (drop (i64.add (local.get $x))))
  (func $sel_i64 (result i64) (unreachable) (select))
  (func $sel_f32 (result f32) (unreachable) (select))
  (func $sel_i32 (result i32) (unreachable) (select))
