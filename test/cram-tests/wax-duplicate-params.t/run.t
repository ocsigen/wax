A parameter name may not be repeated within a signature. This is reported once,
in every context that carries a function-type signature: a function definition,
an explicit type definition, and a tag declaration.

  $ wax check func.wax
  Error: Several parameters have the same name 'x'.
   ──➤  func.wax:1:14
  1 │ fn f(x: i32, x: i32) { }
    ·              ^
    ·      ^ other parameter here
  2 │ 
  [128]

  $ wax check type.wax
  Error: Several parameters have the same name 'a'.
   ──➤  type.wax:1:21
  1 │ type T = fn(a: i32, a: f64);
    ·                     ^
    ·             ^ other parameter here
  2 │ 
  [128]

  $ wax check tag.wax
  Error: Several parameters have the same name 'p'.
   ──➤  tag.wax:1:17
  1 │ tag foo(p: i32, p: i32);
    ·                 ^
    ·         ^ other parameter here
  2 │ 
  [128]
