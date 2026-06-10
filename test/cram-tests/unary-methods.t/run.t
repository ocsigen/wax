The unary instruction methods (the integer and float operators, the
[to_bits]/[from_bits] reinterprets, and array [length]) are written as calls
with parentheses, [x.sqrt()], for consistency with the two-argument methods
like [x.min(y)].

  $ wax --validate methods.wax -f wat
  (type $vec (array (mut i32)))
  
  (func $floats (param $x f64) (result f64)
    (local $a f64) (local $b f64) (local $d i64) (local $e f64)
    (local.set $a (f64.sqrt (local.get $x)))
    (local.set $b (f64.abs (local.get $x)))
    (local.set $d (i64.reinterpret_f64 (local.get $x)))
    (local.set $e (f64.reinterpret_i64 (local.get $d)))
    (f64.add (f64.add (local.get $a) (local.get $b)) (local.get $e))
  )
  
  (func $ints (param $y i32) (param $v (ref $vec)) (result i32)
    (local $c i32) (local $n i32)
    (local.set $c (i32.clz (local.get $y)))
    (local.set $n (array.len (local.get $v)))
    (i32.add (local.get $c) (local.get $n))
  )


The old parenthesis-free form is no longer a method; it is read as a field
access and rejected.

  $ wax check bare.wax
  Error: Expected struct type.
   ──➤  bare.wax:2:5
  1 │ fn f(x: f64) -> f64 {
  2 │     x.sqrt;
    ·     ^
  3 │ }
  4 │ 
  [123]
