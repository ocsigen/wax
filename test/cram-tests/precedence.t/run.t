The `precedence` lint (in the `correctness` group) flags two operator mixes
whose relative precedence is easy to misremember. Wax follows Rust's precedence:
a shift with arithmetic (`+`/`-` bind tighter than `<<` in Rust and C alike, so
`1 << nbits - 1` means `1 << (nbits - 1)`), and a comparison with a bitwise
operator (Rust and Wax bind `&`/`|`/`^` tighter than comparison — the reverse of
C). It is purely syntactic and Wax-only: WAT/WASM have no infix precedence to
misread.

It fires only when the confusingly-tighter operator is not already
parenthesized, so both explicit groupings below stay silent, as does a mix
within one class (`x + y * 2`):

  $ wax check -W precedence=warning prec.wax
  Warning: Operator precedence here is easy to misread.
   ──➤  prec.wax:2:39
  1 │ #[export = "shift_arith"]
  2 │ fn shift_arith(nbits: i32) -> i32 { 1 << nbits - 1; }
    ·                                       ^^
    ·                                                ^ This arithmetic operator binds tighter than the shift operator.
  3 │ 
  4 │ #[export = "cmp_bitwise"]
  Hint: Add parentheses to make the grouping explicit.
  Warning: Operator precedence here is easy to misread.
   ──➤  prec.wax:5:47
  3 │ 
  4 │ #[export = "cmp_bitwise"]
  5 │ fn cmp_bitwise(x: i32, y: i32) -> i32 { x & y == 0; }
    ·                                               ^^
    ·                                           ^ This bitwise operator binds tighter than the comparison operator.
  6 │ 
  7 │ #[export = "paren_inner"]
  Hint: Add parentheses to make the grouping explicit.

The Wax printer adds these same parentheses when it emits code, so decompiled or
reformatted Wax stays quiet under the lint (the confusion table is shared). The
two flagged mixes gain parentheses; the already-parenthesised and same-class
forms are unchanged:

  $ wax convert -f wax prec.wax
  #[export = "shift_arith"]
  fn shift_arith(nbits: i32) -> i32 {
      1 << (nbits - 1);
  }
  
  #[export = "cmp_bitwise"]
  fn cmp_bitwise(x: i32, y: i32) -> i32 {
      (x & y) == 0;
  }
  
  #[export = "paren_inner"]
  fn paren_inner(nbits: i32) -> i32 {
      1 << (nbits - 1);
  }
  
  #[export = "paren_outer"]
  fn paren_outer(nbits: i32) -> i32 {
      (1 << nbits) - 1;
  }
  
  #[export = "same_class"]
  fn same_class(x: i32, y: i32) -> i32 {
      x + y * 2;
  }
