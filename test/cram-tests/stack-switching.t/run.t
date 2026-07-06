Stack-switching primitives (continuation types and the cont_new, cont_bind,
suspend, resume, resume_throw, resume_throw_ref and switch instructions) are
exposed in Wax and compile to WebAssembly, with validation.

  $ wax gen.wax --validate -f wat
  (type $ft0 (func (result i32)))
  (type $k0 (cont $ft0))
  (type $ft1 (func (param i32) (result i32)))
  (type $k1 (cont $ft1))
  (tag $yield (param i32) (result i32))
  (tag $myexn (param i32))
  
  (func $g1 (param $x i32) (result i32) (suspend $yield (local.get $x)))
  
  (func $t_new (result (ref $k1)) (cont.new $k1 (ref.func $g1)))
  (func $t_bind (param $c (ref $k1)) (result (ref $k0))
    (cont.bind $k1 $k0 (i32.const 7) (local.get $c))
  )
  (func $t_resume (param $c (ref $k0)) (result i32) (resume $k0 (local.get $c)))
  (func $t_resume_throw (param $c (ref $k0)) (result i32)
    (resume_throw $k0 $myexn (i32.const 8) (local.get $c))
  )
  (func $t_resume_throw_ref (param $c (ref $k0)) (param $e exnref) (result i32)
    (resume_throw_ref $k0 (local.get $e) (local.get $c))
  )
  
  ;; the abstract cont / nocont heap types are written &cont / &nocont
  (func $abstract_refs (param $a contref) (param $b (ref nocont)) (result i32)
    (i32.const 0)
  )
  (elem declare func $g1)

A WebAssembly module using resume handlers (both `on $tag -> 'label` and
`on $tag -> switch`) and the switch instruction decompiles to Wax:

  $ wax handlers.wat --validate -f wax -o handlers.wax && cat handlers.wax
  // resume with an on-label handler
  type ft = fn(i32) -> i32;
  type ct = cont ft;
  tag yield(i32) -> i32;
  fn handle(k0: &?ct) -> i32 {
      'h: do () -> (i32, &ct) {
          return resume ct [yield -> 'h](1, k0);
      }
      _ = _;
      return _;
  }
  // switch between two continuations
  rec {
      type ft1 = fn(&?ct2) -> i32;
      type ct1 = cont ft1;
      type ft2 = fn(i32) -> i32;
      type ct2 = cont ft2;
  }
  tag e() -> i32;
  fn sw(k: &?ct1) -> i32 {
      switch ct1 e(k);
  }
  // resume with an on-switch handler
  rec { type sft = fn(&?sct) -> i32; type sct = cont sft; }
  tag swap() -> i32;
  fn f: sft (&?sct) -> i32 {
      0;
  }
  fn onsw(k: &?sct) -> i32 {
      resume sct [swap -> switch](k, cont_new sct(f));
  }

The decompiled Wax recompiles and validates, so both directions round-trip.

  $ wax handlers.wax --validate -o out.wasm

Identifiers that collide with the new instruction keywords (`resume`, `switch`,
`suspend`, ...) are renamed when decompiling, so such modules still round-trip.

  $ wax names.wat -f wax -o names.wax && cat names.wax
  type resume_2 = { f: &eq };
  type switch_2 = fn(&resume_2) -> &eq;
  fn suspend_2: switch_2 (x: &resume_2) -> &eq {
      x.f;
  }
  $ wax names.wax --validate -o names.wasm
