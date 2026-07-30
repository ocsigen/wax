A negative integer constant is `UnOp (Neg, Int …)`, not a bare literal, so the
`shift-count-overflow`, `constant-condition`, `constant-trap` and
`tautological-comparison` lints must look through the sign to see it — otherwise
they fire on `x << 1073741824` but silently miss the equivalent
`x << -1073741824`, diverging from the Wasm validator (which sees the folded
`i32.const`). The count is compared unsigned, so a negative count is still at
least the width; a non-zero condition is always true whatever its sign; a `-0` /
`+0` divisor still divides by zero, and `x <u -0` is still the always-false
unsigned comparison against zero. The last three were a lint-parity divergence
the WAT-mutation fuzzer found: the wat form of `x /s -0` reported `constant-trap`
and the wax form said nothing.

The parent `dune` sets `WAX_WARN=correctness=hidden`, so re-enable the group:

  $ wax check -W correctness=warning neg.wax
  Warning [shift-count-overflow]:
    The shift count 18446744072635809792 is at least the operand width (32
    bits).
   ──➤  neg.wax:2:29
  1 │ #[export = "shift"]
  2 │ fn shift(x: i32) -> i32 { x << -1073741824; }
    ·                             ^^
  3 │ 
  4 │ #[export = "cond"]
  Hint: Wasm masks the count modulo 32, shifting by 0 instead.
  Warning [constant-condition]: This condition is always true.
   ──➤  neg.wax:5:23
  3 │ 
  4 │ #[export = "cond"]
  5 │ fn cond() -> i32 { if -117775691 { 1; } else { 2; } }
    ·                       ^^^^^^^^^^
  6 │ 
  7 │ #[export = "div"]
  Warning [constant-trap]:
    This integer division or remainder by zero always traps.
    ──➤  neg.wax:8:27
   6 │ 
   7 │ #[export = "div"]
   8 │ fn div(x: i32) -> i32 { x /s -0; }
     ·                           ^^
   9 │ 
  10 │ #[export = "rem"]
  Warning [constant-trap]:
    This integer division or remainder by zero always traps.
    ──➤  neg.wax:11:27
   9 │ 
  10 │ #[export = "rem"]
  11 │ fn rem(x: i64) -> i64 { x %u +0; }
     ·                           ^^
  12 │ 
  13 │ #[export = "cmp"]
  Warning [tautological-comparison]: This comparison is always false.
    ──➤  neg.wax:14:28
  12 │ 
  13 │ #[export = "cmp"]
  14 │ fn cmp(x: i32) -> i32 { (x <u -0) as i32; }
     ·                            ^^
  15 │ 
