Atomic memory operations (the threads proposal) are written as methods on a
memory whose name is the WAT mnemonic with '.' rewritten as '_'
([mem.i32_atomic_load(p)]); [atomic.fence], which has no memory operand, is the
[atomic::fence()] path intrinsic. Shared memory takes a [shared] clause.

  $ wax --validate atomics.wax -f wat
  (memory $mem 1 1 shared)
  
  (func $load (export "load") (param $p i32) (result i32)
    (i32.atomic.load $mem (local.get $p))
  )
  
  (func $rmw (export "rmw") (param $p i32) (param $v i64) (result i64)
    (i64.atomic.rmw16.add_u $mem (local.get $p) (local.get $v))
  )
  
  (func $cmpxchg (export "cmpxchg")
    (param $p i32) (param $e i32) (param $r i32) (result i32)
    (i32.atomic.rmw.cmpxchg $mem (local.get $p) (local.get $e) (local.get $r))
  )
  
  (func $wait (export "wait")
    (param $p i32) (param $e i32) (param $t i64) (result i32)
    (memory.atomic.wait32 $mem (local.get $p) (local.get $e) (local.get $t))
  )
  
  (func $notify (export "notify") (param $p i32) (param $n i32) (result i32)
    (memory.atomic.notify $mem (local.get $p) (local.get $n))
  )
  
  (func $fence (export "fence") (atomic.fence))

A module using atomics decompiles back to the same method / path forms.

  $ wax roundtrip.wat -f wax
  #[export = "mem"]
  memory mem: i32 [1, 1] shared;
  #[export = "l"]
  fn l(x: i32) -> i32 {
      mem.i32_atomic_load(x);
  }
  #[export = "s"]
  fn s(x: i32, x_2: i64) {
      mem.i64_atomic_store8(x, x_2);
  }
  #[export = "f"]
  fn f() {
      atomic::fence();
  }

An atomic access must use its natural alignment exactly; another value is
rejected.

  $ wax check bad-align.wax
  Error: The alignment of an atomic access must be its natural alignment 4.
   ──➤  bad-align.wax:2:46
  1 │ memory mem: i32 [1, 1] shared;
  2 │ fn f(p: i32) -> i32 { mem.i32_atomic_load(p, 1); }
    ·                                              ^
  3 │ 
  [128]
