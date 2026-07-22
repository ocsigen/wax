The `redundant-operation` lint looks through a leading sign, so an identity
written as a signed literal — here `x + -0` (a `-0` is a `UnOp (Neg, 0)`, not a
bare `0`) — is reported, matching the Wasm validator (which sees the folded
`i64.const 0` directly).

  $ wax check -W redundant-operation=warning negzero.wax
  Warning [redundant-operation]: This operation has no effect on its result.
   ──➤  negzero.wax:2:7
  1 │ fn f(x: i64) -> i64 {
  2 │     x + -0;
    ·       ^
  3 │ }
  4 │ 
