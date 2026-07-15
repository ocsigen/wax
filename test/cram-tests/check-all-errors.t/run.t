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

A dropped statement separator is recovered by *inserting* a `;` rather than
skipping to a boundary: recovery asks the parser whether the erroring state can
shift a `;` (it can, right after a complete statement), so it reports a precise
"Missing ';'" at that point and parses on with the rest intact:

  $ wax check --all-errors missing-semi.wax
  Error: Missing ';'
  
   ──➤  missing-semi.wax:3:5
  1 │ fn f() -> i32 {
  2 │     let x = 1
  3 │     let y = 2;
    ·     ^
  4 │     x + y;
  5 │ }
  [128]

A file with no syntax errors passes silently, exactly as without the flag:

  $ wax check --all-errors clean.wax

The recovered module is still type-checked, so a real type error in an intact
function surfaces alongside the syntax error in a broken one. The spurious
"x is not bound" that the dropped `let x` binding would otherwise cause is
suppressed as a recovery cascade (only the genuine diagnostics remain):

  $ wax check --all-errors mixed.wax
  Error: Expecting an expression.
  
   ──➤  mixed.wax:1:25
  1 │ fn f() -> i32 { let x = ; x + 1; }
    ·                         ^
  2 │ fn g() -> i32 { 1.0; }
  3 │ 
  Error: Expecting type i32 but got type float.
   ──➤  mixed.wax:2:17
  1 │ fn f() -> i32 { let x = ; x + 1; }
  2 │ fn g() -> i32 { 1.0; }
    ·                 ^^^
  3 │ 
  [128]

Recovery drops the value-producing code at a sync boundary, so type-checking
the best-effort AST would find a bare stack underflow ("The stack is empty.")
where the dropped value should have been. That is a cascade from the syntax
error, not a separate mistake, so it is suppressed in recovery mode. Only the
real syntax error is reported (a genuine underflow in intact code still surfaces
on a clean re-check):

  $ wax check --all-errors stack-cascade.wax
  Error: Expecting a statement list.
  
   ──➤  stack-cascade.wax:2:5
  1 │ fn f() -> i32 {
  2 │     @
    ·     ^
  3 │ }
  4 │ 
  [128]

