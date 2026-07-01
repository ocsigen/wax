A "large number" (an integer literal too big for i32) is float-capable — it can
be i64, f32 or f64. A committed "int" (e.g. the result of a bitwise op) is not:
it is i32 or i64 only. Joining the two (an `if`/ternary, or a binary operator) so
the result stays "large number" was unsound: the whole value — including the
integer operation feeding it — could then be coerced to a float, and `to_wasm`
asserted trying to emit, say, an `i64.and` result as an f64. Their only common
type is i64, so the join now pins there.

The `& ` result feeding the ternary is i64, and the ternary is i64:

  $ cat > f.wax <<'WAX'
  > fn f(c: i32) -> i64 {
  >     c ? 5 & 7 : 5000000000;
  > }
  > WAX
  $ wax -i wax f.wax -f wat
  (func $f (param $c i32) (result i64)
    (select (i64.and (i64.const 5) (i64.const 7)) (i64.const 5000000000)
      (local.get $c))
  )

Coercing that (an integer) to a float is now a clean type error rather than an
internal assertion:

  $ cat > g.wax <<'WAX'
  > fn f(c: i32) -> f64 {
  >     (c ? 5 & 7 : 5000000000) + 0.5;
  > }
  > WAX
  $ wax -i wax g.wax -f wasm -o /dev/null --validate
  Error: This operator cannot be applied to operands of types i64 and float.
   ──➤  g.wax:2:30
  1 │ fn f(c: i32) -> f64 {
  2 │     (c ? 5 & 7 : 5000000000) + 0.5;
    ·                              ^
  3 │ }
  4 │ 
  [128]

Likewise a bitwise op with a large-number operand is a committed i64, not a
float-capable value:

  $ cat > h.wax <<'WAX'
  > fn f() -> f64 {
  >     (5 & 5000000000) + 0.5;
  > }
  > WAX
  $ wax -i wax h.wax -f wasm -o /dev/null --validate
  Error: This operator cannot be applied to operands of types i64 and float.
   ──➤  h.wax:2:22
  1 │ fn f() -> f64 {
  2 │     (5 & 5000000000) + 0.5;
    ·                      ^
  3 │ }
  4 │ 
  [128]
