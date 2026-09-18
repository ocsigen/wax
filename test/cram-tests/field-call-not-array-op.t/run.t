`obj.fill(..)` / `obj.copy(..)` / `obj.init(..)` is an array operation only when
`obj` is an array. When `obj` is a struct with a function-pointer field of that
name, the same syntax is an indirect call through the field — the type checker,
`check_hole_order` and `to_wasm` all key the array-operation interpretation on
the receiver being an array, so `to_wasm` must lower this as a `call_ref`, not
mis-emit `array.fill` on a struct type (which would be invalid wasm).

  $ cat > field.wax <<'EOF'
  > type ft = fn(i32);
  > type s = { fill: &ft };
  > #[export = "g"]
  > fn g(x: &s) {
  >     x.fill(5);
  > }
  > EOF

  $ wax -i wax -f wat field.wax --validate
  (type $ft (func (param i32)))
  (type $s (struct (field $fill (ref $ft))))
  (func $g (export "g") (param $x (ref $s))
    (call_ref $ft (i32.const 5) (struct.get $s $fill (local.get $x)))
  )

The same holds for the scalar intrinsic method names (`max`/`min`/`copysign`/
`rotl`/`rotr` and the unary ops): on a struct field they are indirect calls, not
`f64.max` / `f64.sqrt` (which would crash or mis-emit operands in `to_wasm`).

  $ cat > scalar.wax <<'EOF'
  > type bin = fn(f32, f32) -> f32;
  > type un = fn(f32) -> f32;
  > type s = { max: &bin, sqrt: &un };
  > #[export = "g"]
  > fn g(x: &s, a: f32, b: f32) -> f32 {
  >     x.sqrt(x.max(a, b));
  > }
  > EOF

  $ wax -i wax -f wat scalar.wax --validate
  (type $bin (func (param f32 f32) (result f32)))
  (type $un (func (param f32) (result f32)))
  (type $s (struct (field $max (ref $bin)) (field $sqrt (ref $un))))
  (func $g (export "g")
    (param $x (ref $s)) (param $a f32) (param $b f32) (result f32)
    (call_ref $un
      (call_ref $bin (local.get $a) (local.get $b)
        (struct.get $s $max (local.get $x)))
      (struct.get $s $sqrt (local.get $x)))
  )

A genuine array receiver still lowers to `array.fill`:

  $ cat > arr.wax <<'EOF'
  > type a = [mut i32];
  > #[export = "f"]
  > fn f(x: &a) {
  >     x.fill(0, 7, 3);
  > }
  > EOF

  $ wax -i wax -f wat arr.wax --validate
  (type $a (array (mut i32)))
  (func $f (export "f") (param $x (ref $a))
    (array.fill $a (local.get $x) (i32.const 0) (i32.const 7) (i32.const 3))
  )

The interpretation must not turn on the argument *count*. Above, each call
reaches the indirect-call path only because its arity misses the intrinsic's;
at the exact arity the receiver is what decides, so a struct field named
`fill` / `copy` / `init` called with the array operation's own operand count is
still an indirect call.

  $ cat > arity.wax <<'EOF'
  > type fill3 = fn(i32, i32, i32);
  > type copy4 = fn(i32, i32, i32, i32);
  > type init4 = fn(i32, i32, i32, i32);
  > type s = { fill: &fill3, copy: &copy4, init: &init4 };
  > #[export = "g"]
  > fn g(x: &s) {
  >     x.fill(1, 2, 3);
  >     x.copy(1, 2, 3, 4);
  >     x.init(1, 2, 3, 4);
  > }
  > EOF

  $ wax -i wax -f wat arity.wax --validate
  (type $fill3 (func (param i32 i32 i32)))
  (type $copy4 (func (param i32 i32 i32 i32)))
  (type $init4 (func (param i32 i32 i32 i32)))
  (type $s
    (struct
      (field $fill (ref $fill3))
      (field $copy (ref $copy4))
      (field $init (ref $init4)))
  )
  (func $g (export "g") (param $x (ref $s))
    (call_ref $fill3 (i32.const 1) (i32.const 2) (i32.const 3)
      (struct.get $s $fill (local.get $x)))
    (call_ref $copy4 (i32.const 1) (i32.const 2) (i32.const 3) (i32.const 4)
      (struct.get $s $copy (local.get $x)))
    (call_ref $init4 (i32.const 1) (i32.const 2) (i32.const 3) (i32.const 4)
      (struct.get $s $init (local.get $x)))
  )

The zero-argument methods (`length`, and the unary numeric ops) are the same
case at arity zero, and so are the SIMD lane ops and the stack-switching
methods — none of which the receiver's type is allowed to be guessed from.

  $ cat > nullary.wax <<'EOF'
  > type get = fn() -> i32;
  > type lane = fn(v128) -> v128;
  > type sw = fn(i32) -> i32;
  > type s = { length: &get, add_i32x4: &lane, switch: &sw };
  > #[export = "g"]
  > fn g(x: &s, v: v128) -> i32 {
  >     let _ = x.add_i32x4(v);
  >     let _ = x.switch(1);
  >     x.length();
  > }
  > EOF

  $ wax -i wax -f wat nullary.wax --validate
  (type $get (func (result i32)))
  (type $lane (func (param v128) (result v128)))
  (type $sw (func (param i32) (result i32)))
  (type $s
    (struct
      (field $length (ref $get))
      (field $add_i32x4 (ref $lane))
      (field $switch (ref $sw)))
  )
  (func $g (export "g") (param $x (ref $s)) (param $v v128) (result i32)
    (drop
      (call_ref $lane (local.get $v) (struct.get $s $add_i32x4 (local.get $x))))
    (drop (call_ref $sw (i32.const 1) (struct.get $s $switch (local.get $x))))
    (call_ref $get (struct.get $s $length (local.get $x)))
  )

The receiver is not always a plain name: a field read is one too, so the
dispatch resolves it through the struct definition rather than only looking a
name up in the locals.

  $ cat > nested.wax <<'EOF'
  > type bin = fn(i32, i32) -> i32;
  > type inner = { min: &bin };
  > type outer = { i: &inner };
  > #[export = "g"]
  > fn g(o: &outer) -> i32 {
  >     o.i.min(1, 2);
  > }
  > EOF

  $ wax -i wax -f wat nested.wax --validate
  (type $bin (func (param i32 i32) (result i32)))
  (type $inner (struct (field $min (ref $bin))))
  (type $outer (struct (field $i (ref $inner))))
  (func $g (export "g") (param $o (ref $outer)) (result i32)
    (call_ref $bin (i32.const 1) (i32.const 2)
      (struct.get $inner $min (struct.get $outer $i (local.get $o))))
  )

Field names come from the name section, which is under no obligation to avoid
the intrinsic names, so this is a round-trip property and not only a matter of
what can be hand-written: a module whose struct field is named `length`
decompiles to Wax that must compile back to the same module.

  $ cat > names.wat <<'EOF'
  > (module
  >   (type $f (func (result i32)))
  >   (type $h (struct (field $length (ref $f))))
  >   (func $g (export "g") (param $x (ref $h)) (result i32)
  >     (call_ref $f (struct.get $h $length (local.get $x)))))
  > EOF

  $ wax -i wat -f wax names.wat > names.wax
  $ cat names.wax
  type f = fn() -> i32;
  type h = { length: &f };
  #[export]
  fn g(x: &h) -> i32 {
      x.length();
  }
  $ wax -i wat -f wat names.wat > names.fmt.wat
  $ wax -i wax -f wat names.wax --validate | diff - names.fmt.wat

A genuine array or v128 receiver of course still reaches its instruction (a
continuation receiver is covered by `stack-switching.t`):

  $ cat > real.wax <<'EOF'
  > type a = [mut i32];
  > #[export = "len"]
  > fn len(x: &a) -> i32 {
  >     x.length();
  > }
  > #[export = "lanes"]
  > fn lanes(v: v128, w: v128) -> v128 {
  >     v.add_i32x4(w);
  > }
  > EOF

  $ wax -i wax -f wat real.wax --validate
  (type $a (array (mut i32)))
  (func $len (export "len") (param $x (ref $a)) (result i32)
    (array.len (local.get $x))
  )
  (func $lanes (export "lanes") (param $v v128) (param $w v128) (result v128)
    (i32x4.add (local.get $v) (local.get $w))
  )
