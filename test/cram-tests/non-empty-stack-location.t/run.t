When a block (or function body) ends with values still on the stack, the error
points at the leftover value itself rather than at the enclosing construct.

A catch handler whose body leaves a value on the stack — the caret lands on the
offending expression, not the whole try/catch:

  $ wax check try-catch-leftover.wax
  Error: This value remains on the stack.
   ──➤  try-catch-leftover.wax:1:41
  1 │ tag t(); fn f() { try {} catch { t => { 42 as i32; } } }
    ·                                         ^^^^^^^^^
  2 │ 
  [123]

A function body that leaves a value although it declares no result:

  $ wax check fn-leftover.wax
  Error: This value remains on the stack.
   ──➤  fn-leftover.wax:1:10
  1 │ fn f() { 42 as i32; }
    ·          ^^^^^^^^^
  2 │ 
  [123]

When several values are left, a caret lands on each of them:

  $ wax check fn-leftover-multi.wax
  Error: These values remain on the stack.
   ──➤  fn-leftover-multi.wax:1:20
  1 │ fn f() { 1 as i32; 2 as i32; }
    ·                    ^^^^^^^^
    ·          ^^^^^^^^ 
  2 │ 
  [123]
