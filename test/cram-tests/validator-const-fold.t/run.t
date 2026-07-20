The wasm validator folds constants through a demote and reads a shift count
unsigned, matching the Wax typer: a trapping conversion of an out-of-f32-range
constant (`f64.const` → `f32.demote_f64` → `i32.trunc_f32_u`) is flagged even
though the value passes through the demote, and a shift count past 2^63
(`18446744073709551615` = -1) is still recognized as at least the width.

  $ wax check -W correctness=warning fold.wat
  Warning:
    This conversion always traps: the constant is out of the target type's
    range.
   ──➤  fold.wat:3:6
  1 │ (module
  2 │   (func (export "trap") (result i32)
  3 │     (i32.trunc_f32_u (f32.demote_f64 (f64.const 1e300))))
    ·      ^^^^^^^^^^^^^^^
  4 │   (func (export "shift") (param $x i64) (result i64)
  5 │     (i64.shl (local.get $x) (i64.const 18446744073709551615))))
  Warning:
    The shift count 18446744073709551615 is at least the operand width (64
    bits).
   ──➤  fold.wat:5:6
  3 │     (i32.trunc_f32_u (f32.demote_f64 (f64.const 1e300))))
  4 │   (func (export "shift") (param $x i64) (result i64)
  5 │     (i64.shl (local.get $x) (i64.const 18446744073709551615))))
    ·      ^^^^^^^
  6 │ 
  Hint: Wasm masks the count modulo 64, shifting by 63 instead.
