When a block (or function body) ends with values still on the stack, the error
points at the leftover value itself rather than at the enclosing construct.

A catch handler whose body leaves a value on the stack — the caret lands on the
offending expression, not the whole try/catch:

  $ wax check try-catch-leftover.wax
  Error: Some values remain on the stack: i32
   ──➤  try-catch-leftover.wax:1:41
  1 │ tag t(); fn f() { try {} catch { t => { 42 as i32; } } }
    ·                                         ^^^^^^^^^
  2 │ 
  [123]

A function body that leaves a value although it declares no result:

  $ wax check fn-leftover.wax
  Error: Some values remain on the stack: i32
   ──➤  fn-leftover.wax:1:10
  1 │ fn f() { 42 as i32; }
    ·          ^^^^^^^^^
  2 │ 
  [123]
