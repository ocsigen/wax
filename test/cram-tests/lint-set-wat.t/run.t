The correctness lints also run on WebAssembly text/binary input, in the Wasm
validator (so `wax check foo.wat` reports them, as does a validated conversion).
The constant-operand checks are driven by a small constant stack that is cleared
at each non-constant instruction, so they work on both folded and flat WAT — the
last `$flat` function below is the unfolded form of the first.

This directory sets `WAX_WARN=correctness=hidden` (see its `dune`), so re-enable
the tier with an explicit `-W`:

  $ wax check -W correctness=warning lints.wat
  Warning: The shift count 40 is at least the operand width (32 bits).
   ──➤  lints.wat:3:6
  1 │ (module
  2 │   (func $shift (param i32) (result i32)
  3 │     (i32.shl (local.get 0) (i32.const 40)))
    ·      ^^^^^^^
  4 │   (func $divzero (param i32) (result i32)
  5 │     (i32.div_s (local.get 0) (i32.const 0)))
  Hint: Wasm masks the count modulo 32, shifting by 8 instead.
  Warning: This integer division or remainder by zero always traps.
   ──➤  lints.wat:5:6
  3 │     (i32.shl (local.get 0) (i32.const 40)))
  4 │   (func $divzero (param i32) (result i32)
  5 │     (i32.div_s (local.get 0) (i32.const 0)))
    ·      ^^^^^^^^^
  6 │   (func $trunc (result i32)
  7 │     (i32.trunc_f64_s (f64.const 1e30)))
  Warning:
    This conversion always traps: the constant is out of the target type's range.
   ──➤  lints.wat:7:6
  5 │     (i32.div_s (local.get 0) (i32.const 0)))
  6 │   (func $trunc (result i32)
  7 │     (i32.trunc_f64_s (f64.const 1e30)))
    ·      ^^^^^^^^^^^^^^^
  8 │   (func $taut (param i32) (result i32)
  9 │     (i32.ge_u (local.get 0) (i32.const 0)))
  Warning: This comparison is always true.
    ──➤  lints.wat:9:6
   7 │     (i32.trunc_f64_s (f64.const 1e30)))
   8 │   (func $taut (param i32) (result i32)
   9 │     (i32.ge_u (local.get 0) (i32.const 0)))
     ·      ^^^^^^^^
  10 │   (func $constcond (param i32) (result i32)
  11 │     (if (i32.const 0) (then (return (i32.const 1))))
  Warning: This condition is always false.
    ──➤  lints.wat:11:6
   9 │     (i32.ge_u (local.get 0) (i32.const 0)))
  10 │   (func $constcond (param i32) (result i32)
  11 │     (if (i32.const 0) (then (return (i32.const 1))))
     ·      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  12 │     (local.get 0))
  13 │   (func $droppure
  Warning:
    The result of this expression is discarded, and computing it has no effect.
    ──➤  lints.wat:14:6
  12 │     (local.get 0))
  13 │   (func $droppure
  14 │     (drop (i32.const 5)))
     ·      ^^^^
  15 │   (func $dead (result i32)
  16 │     (return (i32.const 1))
  Warning: This code is unreachable.
    ──➤  lints.wat:17:6
  14 │     (drop (i32.const 5)))
  15 │   (func $dead (result i32)
  16 │     (return (i32.const 1))
     ·      ^^^^^^^^^^^^^^^^^^^^^ Control never returns from here.
  17 │     (i32.const 2))
     ·      ^^^^^^^^^^^^
  18 │   (func $flat (param i32) (result i32)
  19 │     local.get 0
  Warning: The shift count 40 is at least the operand width (32 bits).
    ──➤  lints.wat:21:5
  19 │     local.get 0
  20 │     i32.const 40
  21 │     i32.shl))
     ·     ^^^^^^^
  22 │ 
  Hint: Wasm masks the count modulo 32, shifting by 8 instead.
