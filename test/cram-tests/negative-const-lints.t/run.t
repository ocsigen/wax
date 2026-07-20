A negative integer constant is `UnOp (Neg, Int …)`, not a bare literal, so the
`shift-count-overflow` and `constant-condition` lints must look through the sign
to see it — otherwise they fire on `x << 1073741824` but silently miss the
equivalent `x << -1073741824`, diverging from the Wasm validator (which sees the
folded `i32.const`). The count is compared unsigned, so a negative count is still
at least the width; a non-zero condition is always true whatever its sign.

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
