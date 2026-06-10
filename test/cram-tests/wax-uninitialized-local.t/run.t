A local of non-defaultable type (a non-nullable reference) must be assigned
before it is read, as the Wasm validator requires.

Reading a never-assigned local is rejected:

  $ wax check read-uninit.wax
  Error: The local variable 'x' has not been initialized.
   ──➤  read-uninit.wax:2:25
  1 │ type t = fn();
  2 │ fn f() { let x: &t; _ = x; }
    ·                         ^
  3 │ 
  [123]

An assignment inside a block does not escape it, so the local is still
uninitialized afterwards:

  $ wax check set-in-block.wax
  Error: The local variable 'x' has not been initialized.
   ──➤  set-in-block.wax:1:54
  1 │ fn f(p: &extern) { let x: &extern; do { x = p; } _ = x; }
    ·                                                      ^
  2 │ 
  [123]

Likewise an assignment in each branch of an if does not carry past its end:

  $ wax check set-in-if.wax
  Error: The local variable 'x' has not been initialized.
   ──➤  set-in-if.wax:4:9
  2 │     let x: &extern;
  3 │     if 0 as i32 { x = p; } else { x = p; }
  4 │     _ = x;
    ·         ^
  5 │ }
  6 │ 
  [123]

A straight-line assignment before the read is fine:

  $ wax check set-then-read.wax

Defaultable locals (nullable references, numbers) start initialized:

  $ wax check defaultable.wax

A local initialized at its declaration is fine:

  $ wax check init-at-decl.wax
