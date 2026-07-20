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
"Missing ';'" at that point and parses on with the rest intact. Because the
insertion repaired the parse, the error also carries a machine-applicable quick
fix, shown here as the `Help:` line (and serialized as an `edit` object under
`--error-format json`):

  $ wax check --all-errors missing-semi.wax
  Error: Missing ';'.
   ──➤  missing-semi.wax:2:14
  1 │ fn f() -> i32 {
  2 │     let x = 1
    ·              ^
  3 │     let y = 2;
  4 │     x + y;
  Help: insert ';'
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
  Error: This expression has type 'float' but is expected to have type 'i32'.
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
  Error: Assuming that the statement list is complete, expecting '}'.
   ──➤  stack-cascade.wax:2:5
  1 │ fn f() -> i32 {
    ·               ^ This '{' opens the enclosing construct.
  2 │     @
    ·     ^
  3 │ }
  4 │ 
  [128]


When input ends inside an unclosed block, the grammar reduces the empty
statement-list tail (the %on_error_reduce directive in parser.mly) so the error
names the missing '}' and points back at the '{' that opened the block. The hint
is worded locationally ("opens the enclosing construct"), not "unmatched": the
same error state also arises for an invalid token inside an already-closed block
(as in stack-cascade.wax above), where "unmatched" would be false.

  $ wax check --all-errors unclosed-brace.wax
  Error: Assuming that the statement list is complete, expecting '}'.
   ──➤  unclosed-brace.wax:3:1
  1 │ fn f() -> i32 {
    ·               ^ This '{' opens the enclosing construct.
  2 │     let x = 1;
  3 │ 
      ^
  Help: insert '}'
  [128]

--all-errors also covers WAT input. WAT recovery resynchronizes on parentheses:
here the incomplete (v128.const) group is dropped and the unclosed final func is
auto-closed, so both syntax errors are reported, and the best-effort AST is
validated — the genuine i64-into-i32.add type error in the intact middle func
surfaces alongside them. The warnings and the stack-shape cascades a dropped or
auto-closed body would otherwise trigger are suppressed in recovery mode:

  $ wax check --all-errors wat-broken.wat
  Error: Syntax error
   ──➤  wat-broken.wat:2:20
  1 │ (module
  2 │   (func (v128.const))
    ·                    ^
  3 │   (func (result i32) (i32.add (i64.const 1)))
  4 │   (func (i32.const 1)
  Error: Expecting instructions.
   ──➤  wat-broken.wat:5:1
  3 │   (func (result i32) (i32.add (i64.const 1)))
  4 │   (func (i32.const 1)
  5 │ 
      ^
  Help: insert '))'
  Error:
    Type mismatch: this produces a value of type 'i64', but type 'i32' is
    expected.
   ──➤  wat-broken.wat:3:32
  1 │ (module
  2 │   (func (v128.const))
  3 │   (func (result i32) (i32.add (i64.const 1)))
    ·                                ^^^^^^^^^^^
    ·                       ^^^^^^^ expected here
  4 │   (func (i32.const 1)
  5 │ 
  [128]

A well-formed WAT file passes silently, exactly as without the flag:

  $ wax check --all-errors wat-clean.wat


