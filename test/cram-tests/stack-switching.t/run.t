Stack-switching primitives are exposed in Wax and compile to WebAssembly, with
validation. The resume family and switch are methods on the continuation
reference — their type immediate is inferred from the receiver's static type,
on the call_ref model, and the receiver compiles last (Wasm stack order) —
while cont.new/cont.bind are the T::new / T::bind constructors of the declared
continuation type. Handlers are a postfix `on [tag -> 'label, tag -> switch]`
clause and suspend keeps its keyword form.

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
  (func $t_resume_args (param $c (ref $k1)) (param $x i32) (result i32)
    (resume $k1 (local.get $x) (local.get $c))
  )
  (func $t_resume_throw (param $c (ref $k0)) (result i32)
    (resume_throw $k0 $myexn (i32.const 8) (local.get $c))
  )
  (func $t_resume_throw_ref (param $c (ref $k0)) (param $e exnref) (result i32)
    (resume_throw_ref $k0 (local.get $e) (local.get $c))
  )
  
  ;; a receiver that is itself a call result compiles receiver-last, like call_ref
  (func $t_chained (param $x i32) (result i32)
    (resume $k1 (local.get $x) (call $t_new))
  )
  
  ;; a multi-value resume delivers the continuation's full result tuple
  (type $mft (func (result i32 i64)))
  (type $mk (cont $mft))
  (func $t_multi (param $c (ref $mk)) (result i64)
    (local $b i64) (local $a i32)
    (resume $mk (local.get $c))
    (local.set $b)
    (local.set $a)
    (drop (local.get $a))
    (local.get $b)
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
          return k0.resume(1) on [yield -> 'h];
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
      k.switch(tag: e);
  }
  // resume with an on-switch handler
  rec {
      type sft = fn(&?sct) -> i32;
      type sct = cont sft;
  }
  tag swap() -> i32;
  fn f: sft (&?sct) -> i32 {
      0;
  }
  fn onsw(k: &?sct) -> i32 {
      sct::new(f).resume(k) on [swap -> switch];
  }

The decompiled Wax recompiles and validates, so both directions round-trip.

  $ wax handlers.wax --validate -o out.wasm

`resume`, `switch`, ... are plain member names now, so entities may carry those
names without renaming; only the remaining keywords (`suspend`, `on`, `cont`)
force a rename when decompiling.

  $ wax names.wat -f wax -o names.wax && cat names.wax
  type resume = { f: &eq };
  type switch = fn(&resume) -> &eq;
  fn suspend_2: switch (x: &resume) -> &eq {
      x.f;
  }
  $ wax names.wax --validate -o names.wasm

wax -> wasm -> wax is the identity on the decompiled form over every
stack-switching instruction (the receiver-last recovery included):

  $ wax gen.wax -o gen.wasm
  $ wax gen.wasm -f wax -o dec.wax
  $ wax dec.wax -o gen2.wasm
  $ wax gen2.wasm -f wax -o dec2.wax
  $ cmp dec.wax dec2.wax

A resume whose type immediate is a strict supertype of the continuation's own
type decompiles with a compile-time ascription pinning that immediate,
`(c as &?k0).resume(x)`, while a resume at the receiver's own type needs none;
recompiling reproduces both immediates exactly (the ascription lowers to no
instruction).

  $ wax super.wat -f wax -o super.wax && cat super.wax
  type ft0 = open fn(i32) -> i32;
  type k0 = open cont ft0;
  type ft1: ft0 = fn(i32) -> i32;
  type k1: k0 = cont ft1;
  fn up(c: &k1, x: i32) -> i32 {
      (c as &?k0).resume(x);
  }
  fn own(c: &k1, x: i32) -> i32 {
      c.resume(x);
  }
  $ wax super.wax --validate -f wat
  (type $ft0 (sub (func (param i32) (result i32))))
  (type $k0 (sub (cont $ft0)))
  (type $ft1 (sub final $ft0 (func (param i32) (result i32))))
  (type $k1 (sub final $k0 (cont $ft1)))
  (func $up (param $c (ref $k1)) (param $x i32) (result i32)
    (resume $k0 (local.get $x) (local.get $c))
  )
  (func $own (param $c (ref $k1)) (param $x i32) (result i32)
    (resume $k1 (local.get $x) (local.get $c))
  )
