The correctness lints also run on WebAssembly text/binary input, in the Wasm
validator (so `wax check foo.wat` reports them, as does a validated conversion).
The constant-operand checks are driven by a small constant stack that is cleared
at each non-constant instruction, so they work on both folded and flat WAT — the
last `$flat` function below is the unfolded form of the first.

This directory sets `WAX_WARN=correctness=hidden` (see its `dune`), so re-enable
the tier with an explicit `-W`. Every function here is intentionally unused (they
exist only to trigger a lint), so hide the `unused` group to keep the focus on
the constant-operand and dead-code checks (see `unused-fields-wat.t` for those):

  $ wax check -W correctness=warning -W unused=hidden lints.wat
  Warning: The shift count 40 is at least the operand width (32 bits).
   ──➤  lints.wat:4:6
  2 │   (type $pair (struct (field i32) (field i32)))
  3 │   (func $shift (param i32) (result i32)
  4 │     (i32.shl (local.get 0) (i32.const 40)))
    ·      ^^^^^^^
  5 │   (func $divzero (param i32) (result i32)
  6 │     (i32.div_s (local.get 0) (i32.const 0)))
  Hint: Wasm masks the count modulo 32, shifting by 8 instead.
  Warning: This integer division or remainder by zero always traps.
   ──➤  lints.wat:6:6
  4 │     (i32.shl (local.get 0) (i32.const 40)))
  5 │   (func $divzero (param i32) (result i32)
  6 │     (i32.div_s (local.get 0) (i32.const 0)))
    ·      ^^^^^^^^^
  7 │   (func $trunc (result i32)
  8 │     (i32.trunc_f64_s (f64.const 1e30)))
  Warning:
    This conversion always traps: the constant is out of the target type's range.
    ──➤  lints.wat:8:6
   6 │     (i32.div_s (local.get 0) (i32.const 0)))
   7 │   (func $trunc (result i32)
   8 │     (i32.trunc_f64_s (f64.const 1e30)))
     ·      ^^^^^^^^^^^^^^^
   9 │   (func $taut (param i32) (result i32)
  10 │     (i32.ge_u (local.get 0) (i32.const 0)))
  Warning: This comparison is always true.
    ──➤  lints.wat:10:6
   8 │     (i32.trunc_f64_s (f64.const 1e30)))
   9 │   (func $taut (param i32) (result i32)
  10 │     (i32.ge_u (local.get 0) (i32.const 0)))
     ·      ^^^^^^^^
  11 │   (func $constcond (param i32) (result i32)
  12 │     (if (i32.const 0) (then (return (i32.const 1))))
  Warning: This condition is always false.
    ──➤  lints.wat:12:6
  10 │     (i32.ge_u (local.get 0) (i32.const 0)))
  11 │   (func $constcond (param i32) (result i32)
  12 │     (if (i32.const 0) (then (return (i32.const 1))))
     ·      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  13 │     (local.get 0))
  14 │   (func $droppure
  Warning:
    The result of this expression is discarded, and computing it has no effect.
    ──➤  lints.wat:15:6
  13 │     (local.get 0))
  14 │   (func $droppure
  15 │     (drop (i32.const 5)))
     ·      ^^^^
  16 │   (func $dropstruct
  17 │     (drop (struct.new $pair (i32.const 1) (i32.const 2))))
  Warning:
    The result of this expression is discarded, and computing it has no effect.
    ──➤  lints.wat:17:6
  15 │     (drop (i32.const 5)))
  16 │   (func $dropstruct
  17 │     (drop (struct.new $pair (i32.const 1) (i32.const 2))))
     ·      ^^^^
  18 │   (func $dead (result i32)
  19 │     (return (i32.const 1))
  Warning: This code is unreachable.
    ──➤  lints.wat:20:6
  17 │     (drop (struct.new $pair (i32.const 1) (i32.const 2))))
  18 │   (func $dead (result i32)
  19 │     (return (i32.const 1))
     ·      ^^^^^^^^^^^^^^^^^^^^^ Control never returns from here.
  20 │     (i32.const 2))
     ·      ^^^^^^^^^^^^
  21 │   (func $wide (param i64 i64)
  22 │     local.get 0
  Warning:
    The result of this expression is discarded, and computing it has no effect.
    ──➤  lints.wat:25:5
  23 │     local.get 1
  24 │     i64.mul_wide_s
  25 │     drop
     ·     ^^^^
  26 │     drop)
  27 │   (func $flat (param i32) (result i32)
  Warning: The shift count 40 is at least the operand width (32 bits).
    ──➤  lints.wat:30:5
  28 │     local.get 0
  29 │     i32.const 40
  30 │     i32.shl))
     ·     ^^^^^^^
  31 │ 
  Hint: Wasm masks the count modulo 32, shifting by 8 instead.
