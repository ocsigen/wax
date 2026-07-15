When an identifier is not bound, the error suggests the closest names in scope
(by edit distance), drawn from the namespaces the identifier could legitimately
name.

A misspelled function call suggests the function:

  $ wax check func.wax
  Error: The variable 'helpr' is not bound.
   ──➤  func.wax:4:5
  2 │ 
  3 │ fn f() {
  4 │     helpr();
    ·     ^^^^^
  5 │ }
  6 │ 
  Hint: Did you mean 'helper'?
  [128]

A misspelled type suggests the type:

  $ wax check type.wax
  Error: The type 'veec' is not bound.
   ──➤  type.wax:4:26
  2 │ 
  3 │ fn f(p: &vec) -> i32 {
  4 │     let q: &vec = (p as &veec);
    ·                          ^^^^
  5 │     q.length();
  6 │ }
  Hint: Did you mean 'vec'?
  [128]

A misspelled branch label suggests the label:

  $ wax check label.wax
  Error: The label 'nextt' is not bound.
   ──➤  label.wax:3:12
  1 │ fn f() {
  2 │     'next: loop {
  3 │         br 'nextt;
    ·            ^^^^^^
  4 │     }
  5 │ }
  Hint: Did you mean 'next'?
  [128]

An assignment to a misspelled name suggests a mutable global, a valid target:

  $ wax check set_global.wax
  Error: The variable 'countr' is not bound.
   ──➤  set_global.wax:4:5
  2 │ 
  3 │ fn f() {
  4 │     countr = 1;
    ·     ^^^^^^
  5 │ }
  6 │ 
  Hint: Did you mean 'counter'?
  [128]

But an immutable const cannot be assigned, so it is not suggested (no hint):

  $ wax check set_const.wax
  Error: The variable 'limt' is not bound.
   ──➤  set_const.wax:4:5
  2 │ 
  3 │ fn f() {
  4 │     limt = 1;
    ·     ^^^^
  5 │ }
  6 │ 
  [128]

A tee (:=) targets a local, so a misspelled tee suggests the local:

  $ wax check tee_local.wax
  Error: The variable 'valu' is not bound.
   ──➤  tee_local.wax:3:6
  1 │ fn f() -> i32 {
  2 │     let value: i32 = 0;
  3 │     (valu := value) + value;
    ·      ^^^^
  4 │ }
  5 │ 
  Hint: Did you mean 'value'?
  [128]

A tee never targets a global, so a nearby global is not suggested (no hint):

  $ wax check tee_global.wax
  Error: The variable 'countr' is not bound.
   ──➤  tee_global.wax:4:6
  2 │ 
  3 │ fn f() -> i32 {
  4 │     (countr := 1) + 0;
    ·      ^^^^^^
  5 │ }
  6 │ 
  [128]
