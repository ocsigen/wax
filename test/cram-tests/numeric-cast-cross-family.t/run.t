A plain (unsigned) cast never crosses the int/float boundary: converting between
the families is an integer<->float [convert]/[trunc], which needs an explicit
signedness ([as f32_s], [as i32_u]), and a float<->float cast ([demote]/[promote])
has none. Typing accepted several such casts on a value that was still flexible —
a committed integer/float, or a polymorphic reference — and [to_wasm] then hit an
assertion having no instruction to emit. They are now clean type errors, matching
the rejection of the same cast on a concrete [i32]/[f32]. Regressions found by the
AST-mutation fuzzer.

A committed float cast to an integer with a plain cast (no signedness):

  $ echo 'fn f() { (1.0 + 2.0) as i32; }' > a.wax
  $ wax check a.wax
  Error: This value of type float cannot be cast to the target type.
   ──➤  a.wax:1:10
  1 │ fn f() { (1.0 + 2.0) as i32; }
    ·          ^^^^^^^^^^^^^^^^^^
  2 │ 
  Error: This value remains on the stack.
   ──➤  a.wax:1:10
  1 │ fn f() { (1.0 + 2.0) as i32; }
    ·          ^^^^^^^^^^^^^^^^^^
  2 │ 
  [123]

A committed integer cast to a float with a plain cast:

  $ echo 'fn f() { (5 & 3) as f32; }' > b.wax
  $ wax check b.wax
  Error: This value of type int cannot be cast to the target type.
   ──➤  b.wax:1:10
  1 │ fn f() { (5 & 3) as f32; }
    ·          ^^^^^^^^^^^^^^
  2 │ 
  Error: This value remains on the stack.
   ──➤  b.wax:1:10
  1 │ fn f() { (5 & 3) as f32; }
    ·          ^^^^^^^^^^^^^^
  2 │ 
  [123]

A signedness on a float-to-float cast is meaningless:

  $ echo 'fn f(x: f64) -> f32 { x as f32_u; }' > c.wax
  $ wax check c.wax
  Error: This value of type f64 cannot be cast to the target type.
   ──➤  c.wax:1:23
  1 │ fn f(x: f64) -> f32 { x as f32_u; }
    ·                       ^^^^^^^^^^
  2 │ 
  [123]

A polymorphic reference (here [null!] in dead code) cannot convert to a float:

  $ printf 'fn f() -> f32 {\n    unreachable;\n    null! as f32_u;\n}\n' > d.wax
  $ wax check d.wax
  Error: This value of type &_ cannot be cast to the target type.
   ──➤  d.wax:3:5
  1 │ fn f() -> f32 {
  2 │     unreachable;
  3 │     null! as f32_u;
    ·     ^^^^^^^^^^^^^^
  4 │ }
  5 │ 
  [123]

The signed forms, a float->float plain cast, and a numeric literal folded to the
other family all still compile.

  $ printf 'fn f(x: f64, y: i32) -> i32 {\n    (x as f32 as i32_s) + (y as f32_s as i32_s) + (5 as f32 as i32_s);\n}\n' > ok.wax
  $ wax check ok.wax
