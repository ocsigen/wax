When a value is popped from an empty stack while checking a function or block,
the error used to carry a dummy location and printed bare, with no source
context. It now points at the enclosing construct.

A function that promises a result but has an empty body:

  $ wax --validate empty_body.wax -o out.wat
  Error: The stack is empty.
   ──➤  empty_body.wax:1:1
  1 │ fn f() -> i32 {
    · ^^^^^^^^^^^^^^^^
  2 │ }
    · ^
  3 │ 
  [128]

A function whose body produces no value for its declared result:

  $ wax --validate missing_result.wax -o out.wat
  Error: The stack is empty.
   ──➤  missing_result.wax:1:1
  1 │ fn f() -> i32 {
    · ^^^^^^^^^^^^^^^^
  2 │     let x = 1;
    · ^^^^^^^^^^^^^^^
  3 │ }
    · ^
  4 │ 
  [128]
