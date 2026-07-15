The wide-arithmetic instructions are written as [i64::] intrinsics. They take
and return their operands as (low, high) pairs of i64, so each is a call
producing two results, bound with a multi-value [let] or returned directly.

  $ wax --validate wide.wax -f wat
  (func $add (export "add")
    (param $a_lo i64) (param $a_hi i64) (param $b_lo i64) (param $b_hi i64)
    (result i64 i64)
    (local $hi i64) (local $lo i64)
    (i64.add128 (local.get $a_lo) (local.get $a_hi) (local.get $b_lo)
      (local.get $b_hi))
    (local.set $hi)
    (local.set $lo)
    (local.get $lo)
    (local.get $hi)
  )
  
  (func $sub (export "sub")
    (param $a_lo i64) (param $a_hi i64) (param $b_lo i64) (param $b_hi i64)
    (result i64 i64)
    (i64.sub128 (local.get $a_lo) (local.get $a_hi) (local.get $b_lo)
      (local.get $b_hi))
  )
  
  (func $mul_s (export "mul_s") (param $a i64) (param $b i64) (result i64 i64)
    (i64.mul_wide_s (local.get $a) (local.get $b))
  )
  
  (func $mul_u (export "mul_u") (param $a i64) (param $b i64) (result i64 i64)
    (i64.mul_wide_u (local.get $a) (local.get $b))
  )

A module using them round-trips back from WebAssembly text to the same [i64::]
form (here both results flow straight to the function's results, so no binding
is needed).

  $ wax roundtrip.wat -f wax
  #[export]
  fn add(x: i64, x_2: i64, x_3: i64, x_4: i64) -> (i64, i64) {
      i64::add128(x, x_2, x_3, x_4);
  }
  #[export]
  fn mul(x: i64, x_2: i64) -> (i64, i64) {
      i64::mul_wide_u(x, x_2);
  }

An unknown member of the [i64] namespace is rejected.

  $ wax check bad-name.wax
  Error: There is no 'i64::add256' intrinsic.
   ──➤  bad-name.wax:2:5
  1 │ fn f(a: i64, b: i64) -> (i64, i64) {
  2 │     i64::add256(a, b);
    ·     ^^^^^^^^^^^^^^^^^
  3 │ }
  4 │ 
  [128]

Passing the wrong number of operands is a value-count mismatch.

  $ wax check bad-arity.wax
  Error: This instruction provides 2 value(s) but 4 was/were expected.
   ──➤  bad-arity.wax:2:5
  1 │ fn f(a_lo: i64, a_hi: i64) -> (i64, i64) {
  2 │     i64::add128(a_lo, a_hi);
    ·     ^^^^^^^^^^^^^^^^^^^^^^^
  3 │ }
  4 │ 
  [128]
