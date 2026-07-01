A LargeInt (an integer literal beyond i32) coerces to f32/f64 in a binary
operator, as it does in the subtype lattice — so it pairs with a float operand
like a small Number literal does. This lets an integer-valued float constant
(e.g. an f32.const decompiled to a bare literal) round-trip. Regression: found by
the WAT-mutation fuzzer.

  $ cat > f.wax <<'EOF'
  > fn add(x: f32) -> f32 { x + 4294967296; }
  > fn cmp(x: f64) -> i32 { x < 4294967296; }
  > fn div(x: f32) -> f32 { x / -4294967296; }
  > EOF
  $ wax -i wax -f wasm f.wax -o /dev/null --validate

An explicit [as f32]/[as f64] cast of a LargeInt folds the literal to a float
constant, exactly like a small [Int] operand (`5 as f64` -> `f64.const 5`) — not
an unlowerable [i64] value. This is the operand [from_wasm] emits when wrapping a
reinterpret's argument; before, it reached [to_wasm] as a bare [i64 as f64] and
crashed. Regression: found by the WAT-mutation fuzzer.

  $ cat > cast.wax <<'EOF'
  > fn f() -> i64 { (0xffffffffffffffff as f64).to_bits(); }
  > fn g(x: f32) { _ = (0xffffffffffffffff as f32); }
  > EOF
  $ wax -i wax -f wat cast.wax --validate
  (func $f (result i64) (i64.reinterpret_f64 (f64.const 0xffffffffffffffff)))
  (func $g (param $x f32) (drop (f32.const 0xffffffffffffffff)))

A non-numeric pairing is still rejected:

  $ printf 'fn f(x: f32) -> f32 {\n    x & 4294967296;\n}\n' > bad.wax
  $ wax -i wax -f wasm bad.wax -o /dev/null
  Error: This operator cannot be applied to operands of types f32 and int.
   ──➤  bad.wax:2:7
  1 │ fn f(x: f32) -> f32 {
  2 │     x & 4294967296;
    ·       ^
  3 │ }
  4 │ 
  [128]
