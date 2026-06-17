A struct or array literal may omit its type name when an expected type (here a
let or const annotation) supplies it; the file type-checks cleanly:

  $ wax check ok.wax

With no expected type the name cannot be inferred, and it is reported:

  $ wax check no-struct-context.wax
  Error:
    Cannot infer the struct type here; add an explicit type, as in '{T| ..}'.
   ──➤  no-struct-context.wax:4:13
  2 │ 
  3 │ fn f() -> &point {
  4 │     let p = {x: 1, y: 2,};
    ·             ^^^^^^^^^^^^^
  5 │     return p;
  6 │ }
  Error: This instruction has type i32 but is expected to have type &point.
   ──➤  no-struct-context.wax:5:12
  3 │ fn f() -> &point {
  4 │     let p = {x: 1, y: 2,};
  5 │     return p;
    ·            ^
  6 │ }
  7 │ 
  [123]

  $ wax check no-array-context.wax
  Error:
    Cannot infer the array type here; add an explicit type, as in '[T| ..]'.
   ──➤  no-array-context.wax:4:13
  2 │ 
  3 │ fn f() -> &ints {
  4 │     let a = [0; 8];
    ·             ^^^^^^
  5 │     return a;
  6 │ }
  Error: This instruction has type i32 but is expected to have type &ints.
   ──➤  no-array-context.wax:5:12
  3 │ fn f() -> &ints {
  4 │     let a = [0; 8];
  5 │     return a;
    ·            ^
  6 │ }
  7 │ 
  [123]
