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
