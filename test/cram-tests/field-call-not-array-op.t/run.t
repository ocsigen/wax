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
