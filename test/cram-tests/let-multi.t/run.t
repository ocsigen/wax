A `let` may bind several names at once from a multi-value initializer, written
as a parenthesised list. Each name takes the corresponding value; the
initializer is evaluated once and its results are stored into the locals in
reverse order (the last value is on top of the stack). Names may be annotated,
inferred, or discarded with `_`.

  $ wax --validate multi.wax -f wat
  (func $divmod (param $a i32) (param $b i32) (result i32 i32)
    (i32.div_s (local.get $a) (local.get $b))
    (i32.rem_s (local.get $a) (local.get $b))
  )
  
  (func $inferred (result i32)
    (local $q i32) (local $r i32)
    (call $divmod (i32.const 17) (i32.const 5))
    (local.set $r)
    (local.set $q)
    (i32.add (local.get $q) (local.get $r))
  )
  
  (func $annotated (result i32)
    (local $q i32) (local $r i32)
    (call $divmod (i32.const 17) (i32.const 5))
    (local.set $r)
    (local.set $q)
    (local.get $q)
  )
  
  (func $discard (result i32)
    (local $q i32)
    (call $divmod (i32.const 17) (i32.const 5))
    (drop)
    (local.set $q)
    (local.get $q)
  )




The number of names must match the number of values the initializer provides.

  $ wax check bad-count.wax
  Error: This instruction provides 2 value(s) but 3 was/were expected.
   ──➤  bad-count.wax:7:5
  5 │ 
  6 │ fn f() -> i32 {
  7 │     let (x, y, z) = divmod(1, 2);
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  8 │     x;
  9 │ }
  [123]

An annotation is checked against the value bound to that name.

  $ wax check bad-type.wax
  Error: This instruction has type i32 but is expected to have type i64.
   ──➤  bad-type.wax:7:5
  5 │ 
  6 │ fn f() -> i64 {
  7 │     let (x: i64, y) = divmod(1, 2);
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  8 │     x;
  9 │ }
  [123]
