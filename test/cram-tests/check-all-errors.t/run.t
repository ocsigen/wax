By default 'check' reports the first syntax error and stops (the parser gives
up at the first unexpected token):

  $ wax check multi.wax
  Error: Expecting an expression.
  
   ──➤  multi.wax:2:13
  1 │ fn f() -> i32 {
  2 │     let x = ;
    ·             ^
  3 │     let y = * 2;
  4 │     x + y;
  [128]

--all-errors turns on panic-mode recovery: the parser resynchronizes at
statement/block boundaries and keeps going, so every syntax error is reported
in one run (here both the empty initializer on line 2 and the missing left
operand on line 3):

  $ wax check --all-errors multi.wax
  Error: Expecting an expression.
  
   ──➤  multi.wax:2:13
  1 │ fn f() -> i32 {
  2 │     let x = ;
    ·             ^
  3 │     let y = * 2;
  4 │     x + y;
  Error: Expecting an expression.
  
   ──➤  multi.wax:3:13
  1 │ fn f() -> i32 {
  2 │     let x = ;
  3 │     let y = * 2;
    ·             ^
  4 │     x + y;
  5 │ }
  [128]

A file with no syntax errors passes silently, exactly as without the flag:

  $ wax check --all-errors clean.wax
