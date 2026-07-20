A value carried by `br` to a block's label must be a subtype of the block's
result type, just like the block's fall-through value. When that result type is
pinned by the context (here the function's return type) rather than annotated,
the typer must still reject a mismatched branch value — it used to compute the
subtype check but discard its verdict, accepting the module and only rejecting it
later during lowering.

  $ wax check context-typed.wax
  Error: This expression has type 'number' but is expected to have type 'v128'.
   ──➤  context-typed.wax:4:15
  2 │ fn f() -> v128 {
  3 │     'l: do {
  4 │         br 'l 0;
    ·               ^
  5 │     }
  6 │ }
  [128]

The same check applies when the block's result type is written explicitly:

  $ wax check annotated.wax
  Error: This expression has type 'i64' but is expected to have type 'i32'.
   ──➤  annotated.wax:4:16
  2 │ fn g() -> i32 {
  3 │     'l: do i32 {
  4 │         br 'l (0 as i64);
    ·                ^^^^^^^^
  5 │     }
  6 │ }
  [128]
