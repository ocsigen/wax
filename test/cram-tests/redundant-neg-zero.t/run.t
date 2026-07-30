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

A unary negation has no Wasm instruction of its own: `-e` lowers to `0 - e`, so
the Wasm validator sees the `x - 0` identity whenever `e` is zero, and reports it
on the lowered form. The typer mirrors that, for the one shape which reaches it —
a bare literal folds (`-0` becomes the constant, emitting no subtraction at all,
so neither side says anything) while a negation of anything else zero-valued does
emit the subtraction. Each shape on its own line, so each report is
unambiguous — only the first fires:

  $ cat > unary.wax <<'WAX'
  > #[export]
  > fn f(x: i32) -> i32 {
  >     _ = --0;
  >     _ = -0;
  >     -x;
  > }
  > WAX
  $ wax check -W redundant-operation=warning --error-format short unary.wax
  unary.wax:3:9: warning: This operation has no effect on its result. [redundant-operation]

The lowered form reports the same one identity, so the two linters agree on this
program (a lint-parity finding from the wax mutation fuzzer, where the wat form
reported what the typer did not):

  $ wax unary.wax -f wat -o unary.wat && wax check -W redundant-operation=warning --error-format short unary.wat
  unary.wat:2:10: warning: This operation has no effect on its result. [redundant-operation]

Floats keep their negation: `-0.0` genuinely produces negative zero, so it is not
an identity — and the validator's own check is integer-only for the same reason.

  $ cat > float.wax <<'WAX'
  > #[export]
  > fn g(y: f64) -> f64 {
  >     (- -0x0p+0) + y;
  > }
  > WAX
  $ wax check -W redundant-operation=warning --error-format short float.wax
