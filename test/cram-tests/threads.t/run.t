Atomic memory operations (the threads proposal) are written as methods on a
memory following the scalar-access naming convention: the access width is in
the name ([mem.atomic_load32(p)], [mem.atomic_rmw_add16(p, v)]), the i32/i64
value type comes from the operand and result types, and a narrow load is
resolved by an [as iN_u] cast ([mem.atomic_load8(p) as i64_u], fused into the
single zero-extending instruction). [atomic.fence], which has no memory
operand, is the [atomic::fence()] path intrinsic. Shared memory takes a
[shared] clause.

  $ wax --validate atomics.wax -f wat
  (memory $mem 1 1 shared)
  
  ;; The function types are declared (and named) up front so the wasm round-trip
  ;; in run.t is byte-identical: left synthesized, the decompiler would have to
  ;; invent names for them, which land in the recompiled binary's name section.
  (type $loader (func (param i32) (result i32)))
  (type $loader64 (func (param i32) (result i64)))
  (type $storer (func (param i32 i32 i64)))
  (type $rmw64_t (func (param i32 i64) (result i64)))
  (type $rmw32_t (func (param i32 i32) (result i32)))
  (type $cmpxchg32_t (func (param i32 i32 i32) (result i32)))
  (type $cmpxchg64_t (func (param i32 i64 i64) (result i64)))
  (type $waiter32 (func (param i32 i32 i64) (result i32)))
  (type $waiter64 (func (param i32 i64 i64) (result i32)))
  (type $nullary (func))
  
  (func $load (export "load") (param $p i32) (result i32)
    (i32.atomic.load $mem (local.get $p))
  )
  
  (func $load64 (export "load64") (param $p i32) (result i64)
    (i64.atomic.load $mem (local.get $p))
  )
  
  (func $narrow_loads (export "narrow_loads") (param $p i32) (result i64)
    (local $a i32) (local $b i32) (local $c i64) (local $d i64) (local $e i64)
    (local $f i64)
    (local.set $a
      (i32.atomic.load8_u $mem (local.get $p))) ;; i32.atomic.load8_u
    (local.set $b
      (i32.atomic.load16_u $mem (local.get $p))) ;; i32.atomic.load16_u
    (local.set $c
      (i64.atomic.load8_u $mem (local.get $p))) ;; i64.atomic.load8_u
    (local.set $d
      (i64.atomic.load16_u $mem (local.get $p))) ;; i64.atomic.load16_u
    (local.set $e
      (i64.atomic.load32_u $mem (local.get $p))) ;; i64.atomic.load32_u (fused)
    (local.set $f
      (i64.extend_i32_s
        (i32.atomic.load $mem
          (local.get $p)))) ;; i32.atomic.load; i64.extend_i32_s
    (i64.add
      (i64.add (i64.add (i64.add (local.get $c) (local.get $d)) (local.get $e))
        (local.get $f))
      (i64.extend_i32_u (i32.add (local.get $a) (local.get $b))))
  )
  
  (func $stores (export "stores") (param $p i32) (param $v i32) (param $w i64)
    (i32.atomic.store8 $mem (local.get $p) (local.get $v)) ;; i32.atomic.store8
    (i64.atomic.store16 $mem (local.get $p)
      (local.get $w)) ;; i64.atomic.store16
    (i32.atomic.store $mem (local.get $p) (local.get $v)) ;; i32.atomic.store
    (i64.atomic.store32 $mem (local.get $p)
      (local.get $w)) ;; i64.atomic.store32
    (i64.atomic.store $mem (local.get $p) (local.get $w)) ;; i64.atomic.store
    (i32.atomic.store8 $mem (local.get $p)
      (i32.const 1)) ;; a flexible literal defaults to i32
  )
  
  (func $rmw (export "rmw") (param $p i32) (param $v i64) (result i64)
    (i64.atomic.rmw16.add_u $mem (local.get $p)
      (local.get $v)) ;; i64.atomic.rmw16.add_u
  )
  
  (func $rmw32 (export "rmw32") (param $p i32) (param $v i32) (result i32)
    (i32.atomic.rmw.sub $mem (local.get $p)
      (local.get $v)) ;; i32.atomic.rmw.sub
  )
  
  (func $rmw64 (export "rmw64") (param $p i32) (param $v i64) (result i64)
    (i64.atomic.rmw.xchg $mem (local.get $p)
      (local.get $v)) ;; i64.atomic.rmw.xchg
  )
  
  (func $cmpxchg (export "cmpxchg")
    (param $p i32) (param $e i32) (param $r i32) (result i32)
    (i32.atomic.rmw.cmpxchg $mem (local.get $p) (local.get $e)
      (local.get $r)) ;; i32.atomic.rmw.cmpxchg
  )
  
  (func $cmpxchg8 (export "cmpxchg8")
    (param $p i32) (param $e i64) (param $r i64) (result i64)
    (i64.atomic.rmw8.cmpxchg_u $mem (local.get $p) (local.get $e)
      (local.get $r)) ;; i64.atomic.rmw8.cmpxchg_u
  )
  
  (func $wait (export "wait")
    (param $p i32) (param $e i32) (param $t i64) (result i32)
    (memory.atomic.wait32 $mem (local.get $p) (local.get $e) (local.get $t))
  )
  
  (func $wait64 (export "wait64")
    (param $p i32) (param $e i64) (param $t i64) (result i32)
    (memory.atomic.wait64 $mem (local.get $p) (local.get $e) (local.get $t))
  )
  
  (func $notify (export "notify") (param $p i32) (param $n i32) (result i32)
    (memory.atomic.notify $mem (local.get $p) (local.get $n))
  )
  
  (func $fence (export "fence") (atomic.fence))

Decompiling the compiled module reconstructs the same method names (narrow
loads with their resolving cast), and recompiling the decompiled form
reproduces the binary byte for byte. (The source declares its function types
so their names round-trip; otherwise the decompiler synthesizes names, which
would differ in the recompiled binary's name section.)

  $ wax atomics.wax -o atomics.wasm
  $ wax atomics.wasm -f wax -o decompiled.wax
  $ cat decompiled.wax
  type loader = fn(i32) -> i32;
  type loader64 = fn(i32) -> i64;
  type storer = fn(i32, i32, i64);
  type rmw64_t = fn(i32, i64) -> i64;
  type rmw32_t = fn(i32, i32) -> i32;
  type cmpxchg32_t = fn(i32, i32, i32) -> i32;
  type cmpxchg64_t = fn(i32, i64, i64) -> i64;
  type waiter32 = fn(i32, i32, i64) -> i32;
  type waiter64 = fn(i32, i64, i64) -> i32;
  type nullary = fn();
  #[export]
  fn load(p: i32) -> i32 {
      mem.atomic_load32(p);
  }
  #[export]
  fn load64(p: i32) -> i64 {
      mem.atomic_load64(p);
  }
  #[export]
  fn narrow_loads(p: i32) -> i64 {
      let a = mem.atomic_load8(p) as i32_u;
      let b = mem.atomic_load16(p) as i32_u;
      let c = mem.atomic_load8(p) as i64_u;
      let d = mem.atomic_load16(p) as i64_u;
      let e = mem.atomic_load32(p) as i64_u;
      let f = mem.atomic_load32(p) as i64_s;
      c + d + e + f + (a + b) as i64_u;
  }
  #[export]
  fn stores(p: i32, v: i32, w: i64) {
      mem.atomic_store8(p, v);
      mem.atomic_store16(p, w);
      mem.atomic_store32(p, v);
      mem.atomic_store32(p, w);
      mem.atomic_store64(p, w);
      mem.atomic_store8(p, 1);
  }
  #[export]
  fn rmw(p: i32, v: i64) -> i64 {
      mem.atomic_rmw_add16(p, v);
  }
  #[export]
  fn rmw32(p: i32, v: i32) -> i32 {
      mem.atomic_rmw_sub32(p, v);
  }
  #[export]
  fn rmw64(p: i32, v: i64) -> i64 {
      mem.atomic_rmw_xchg64(p, v);
  }
  #[export]
  fn cmpxchg(p: i32, e: i32, r: i32) -> i32 {
      mem.atomic_rmw_cmpxchg32(p, e, r);
  }
  #[export]
  fn cmpxchg8(p: i32, e: i64, r: i64) -> i64 {
      mem.atomic_rmw_cmpxchg8(p, e, r);
  }
  #[export]
  fn wait(p: i32, e: i32, t: i64) -> i32 {
      mem.atomic_wait32(p, e, t);
  }
  #[export]
  fn wait64(p: i32, e: i64, t: i64) -> i32 {
      mem.atomic_wait64(p, e, t);
  }
  #[export]
  fn notify(p: i32, n: i32) -> i32 {
      mem.atomic_notify(p, n);
  }
  #[export]
  fn fence() {
      atomic::fence();
  }
  memory mem: i32 [1, 1] shared;
  $ wax decompiled.wax -o again.wasm
  $ cmp atomics.wasm again.wasm

A module using atomics decompiles back to the same method / path forms.

  $ wax roundtrip.wat -f wax
  #[export]
  memory mem: i32 [1, 1] shared;
  #[export]
  fn l(x: i32) -> i32 {
      mem.atomic_load32(x);
  }
  #[export]
  fn s(x: i32, x_2: i64) {
      mem.atomic_store8(x, x_2);
  }
  #[export]
  fn f() {
      atomic::fence();
  }

A narrow atomic load returns raw bits, so it needs a resolving [as iN_u] cast;
the sign-extending forms do not exist and are rejected with the spelling to
use instead. A 64-bit access requires an i64 value, and the two cmpxchg values
must agree on their type.

  $ wax check errors.wax
  Error: This expression has type 'i8' but is expected to have type 'i32'.
   ──➤  errors.wax:3:5
  1 │ memory mem: i32 [1, 1] shared;
  2 │ fn missing_cast(p: i32) -> i32 {
  3 │     mem.atomic_load8(p);
    ·     ^^^^^^^^^^^^^^^^^^^
  4 │ }
  5 │ fn signed8(p: i32) -> i32 {
  Error:
    An atomic load zero-extends; use 'as i32_u', then '.extend8_s()' if you need
    the sign.
   ──➤  errors.wax:6:5
  4 │ }
  5 │ fn signed8(p: i32) -> i32 {
  6 │     mem.atomic_load8(p) as i32_s;
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  7 │ }
  8 │ fn signed16(p: i32) -> i64 {
  Error:
    An atomic load zero-extends; use 'as i64_u', then '.extend16_s()' if you
    need the sign.
    ──➤  errors.wax:9:5
   7 │ }
   8 │ fn signed16(p: i32) -> i64 {
   9 │     mem.atomic_load16(p) as i64_s;
     ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  10 │ }
  11 │ fn narrow64(p: i32, v: i32) {
  Error: This expression has type 'i32' but is expected to have type 'i64'.
    ──➤  errors.wax:12:27
  10 │ }
  11 │ fn narrow64(p: i32, v: i32) {
  12 │     mem.atomic_store64(p, v);
     ·                           ^
  13 │ }
  14 │ fn mixed_cmpxchg(p: i32, e: i32, r: i64) -> i32 {
  Error: This operator cannot be applied to operands of types 'i32' and 'i64'.
    ──➤  errors.wax:15:36
  13 │ }
  14 │ fn mixed_cmpxchg(p: i32, e: i32, r: i64) -> i32 {
  15 │     mem.atomic_rmw_cmpxchg16(p, e, r);
     ·                                    ^
  16 │ }
  17 │ 
  [128]

An atomic access must use its natural alignment — the access width from the
method name, whichever value type the operands select; another value is
rejected.

  $ wax check bad-align.wax
  Error: The alignment of an atomic access must be its natural alignment 4.
   ──➤  bad-align.wax:2:51
  1 │ memory mem: i32 [1, 1] shared;
  2 │ fn f(p: i32) -> i32 { mem.atomic_load32(p, align: 1); }
    ·                                                   ^
  3 │ fn g(p: i32, v: i64) -> i64 { mem.atomic_rmw_add16(p, v, align: 4); }
  4 │ 
  Error: The alignment of an atomic access must be its natural alignment 2.
   ──➤  bad-align.wax:3:65
  1 │ memory mem: i32 [1, 1] shared;
  2 │ fn f(p: i32) -> i32 { mem.atomic_load32(p, align: 1); }
  3 │ fn g(p: i32, v: i64) -> i64 { mem.atomic_rmw_add16(p, v, align: 4); }
    ·                                                                 ^
  4 │ 
  [128]
