Reference equality supports both `==` and `!=`. WebAssembly has only `ref.eq`,
so `a == b` is a bare `ref.eq` and `a != b` negates it with `i32.eqz`.

  $ wax ref-ne.wax -f wat
  (func $eq (param $a (ref eq)) (param $b (ref eq)) (result i32)
    (ref.eq (local.get $a) (local.get $b))
  )
  (func $ne (param $a (ref eq)) (param $b (ref eq)) (result i32)
    (i32.eqz (ref.eq (local.get $a) (local.get $b)))
  )

`!=` accepts the same operands as `==` (a subtype of `&eq`), so a comparison of
non-equatable references is rejected the same way for both operators.

  $ wax check bad-ne.wax
  Error:
    This operator cannot be applied to operands of types '&func' and '&func'.
   ──➤  bad-ne.wax:2:7
  1 │ fn f(a: &func, b: &func) -> i32 {
  2 │     a != b;
    ·       ^^
  3 │ }
  4 │ 
  [128]
