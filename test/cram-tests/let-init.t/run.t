A `let` binding may carry an initializer. With a type annotation the
initializer is checked (and a polymorphic literal is resolved) against it; with
no annotation the local takes the initializer's type, defaulting an
unconstrained literal the way the type checker does (int -> i32, float -> f64).

  $ wax --validate let.wax -f wat
  (func $typed (result i64)
    (local $x i64)
    (local.set $x (i64.const 7))
    (local.get $x)
  )
  
  (func $inferred (result f64)
    (local $n i32) (local $f f64)
    (local.set $n (i32.const 1))
    (local.set $f (f64.const 2.5))
    (local.get $f)
  )

A type mismatch between the annotation and the initializer is reported.

  $ wax --validate bad.wax -f wat
  Error: This instruction has type float but is expected to have type i32.
   ──➤  bad.wax:2:18
  1 │ fn f() -> i32 {
  2 │     let x: i32 = 2.5;
    ·                  ^^^
  3 │     x;
  4 │ }
  [128]
