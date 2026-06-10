Wax type-checking verifies operand and result types that the Wasm validator
also checks.

A float-only method requires a floating-point receiver:

  $ wax check float-method-bad.wax
  Error: This operation cannot be applied to a value of type i64.
   ──➤  float-method-bad.wax:1:18
  1 │ fn f() -> f32 { (0 as i64).ceil(); }
    ·                  ^^^^^^^^
  2 │ 
  [123]

An integer-only method requires an integer receiver:

  $ wax check int-method-bad.wax
  Error: This operation cannot be applied to a value of type f32.
   ──➤  int-method-bad.wax:1:18
  1 │ fn f() -> i32 { (0.0 as f32).clz(); }
    ·                  ^^^^^^^^^^
  2 │ 
  [123]

table.copy requires the source element type to fit the destination:

  $ wax check table-copy-bad.wax
  Error: This instruction has type &?extern but is expected to have type
    &?func.
   ──➤  table-copy-bad.wax:3:10
  1 │ table t1: &?func [10];
  2 │ table t2: &?extern [10];
  3 │ fn f() { t1.copy(t2, 0 as i32, 1 as i32, 2 as i32); }
    ·          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │ 
  [123]

table.init requires the element segment's type to fit the table:

  $ wax check table-init-bad.wax
  Error: This instruction has type &?extern but is expected to have type
    &?func.
   ──➤  table-init-bad.wax:3:10
  1 │ table t: &?func [10];
  2 │ elem el: &?extern = [];
  3 │ fn f() { t.init(el, 0 as i32, 1 as i32, 2 as i32); }
    ·          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │ 
  [123]

array.init_elem requires the element segment's type to fit the array:

  $ wax check array-init-elem-bad.wax
  Error: This instruction has type &?extern but is expected to have type
    &?func.
   ──➤  array-init-elem-bad.wax:3:15
  1 │ type a = [mut &?func];
  2 │ elem e: &?extern = [];
  3 │ fn f(x: &a) { x.init(e, 0 as i32, 0 as i32, 0 as i32); }
    ·               ^
  4 │ 
  [123]

An 'if' that produces a result must have an 'else' branch:

  $ wax check if-no-else.wax
  Error: This 'if' must produce a value and so requires an 'else' branch.
   ──➤  if-no-else.wax:1:17
  1 │ fn f() -> i32 { if 1 as i32 => i32 { 0 as i32; } }
    ·                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [123]

Matching element types and correct receivers pass:

  $ wax check ok.wax
