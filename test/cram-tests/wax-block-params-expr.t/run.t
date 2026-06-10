A block, loop or if used as an expression has no stack to draw from, so it
cannot take parameters. This is reported, rather than crashing the
type-checker:

  $ wax check block.wax
  Error: A block, loop or if used as an expression cannot take parameters.
   ──➤  block.wax:1:33
  1 │ fn f() -> i32 { _ = 1 as i32 + (do (i32) -> i32 { }); 0 as i32; }
    ·                                 ^^^^^^^^^^^^^^^^^^^
  2 │ 
  Error: The stack is empty.
   ──➤  block.wax:1:33
  1 │ fn f() -> i32 { _ = 1 as i32 + (do (i32) -> i32 { }); 0 as i32; }
    ·                                 ^^^^^^^^^^^^^^^^^^^
  2 │ 
  [123]

  $ wax check loop.wax
  Error: A block, loop or if used as an expression cannot take parameters.
   ──➤  loop.wax:1:26
  1 │ fn f() { _ = 1 as i32 + (loop (i32) -> i32 { }); }
    ·                          ^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  Error: The stack is empty.
   ──➤  loop.wax:1:26
  1 │ fn f() { _ = 1 as i32 + (loop (i32) -> i32 { }); }
    ·                          ^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [123]

  $ wax check if.wax
  Error: A block, loop or if used as an expression cannot take parameters.
   ──➤  if.wax:1:22
  1 │ fn f() -> i32 { _ = (if 1 as i32 => (i32) -> i32 { } else { }); 0 as i32; }
    ·                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  Error: The stack is empty.
   ──➤  if.wax:1:22
  1 │ fn f() -> i32 { _ = (if 1 as i32 => (i32) -> i32 { } else { }); 0 as i32; }
    ·                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  Error: The stack is empty.
   ──➤  if.wax:1:22
  1 │ fn f() -> i32 { _ = (if 1 as i32 => (i32) -> i32 { } else { }); 0 as i32; }
    ·                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [123]
