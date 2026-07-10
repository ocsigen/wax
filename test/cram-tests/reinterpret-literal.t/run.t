A reinterpret (`to_bits`/`from_bits`) needs a concretely-typed operand. When the
operand is a numeric literal, decompiling from Wasm wraps it in a cast; the
[simplify] pass then keeps that cast only when it is load-bearing — i.e. when the
target width differs from the width the bare literal would default to (int ->
i32, float -> f64). So `f32`/`i64` reinterprets keep their cast, while the
`f64`/`i32` ones (matching the literal's default) drop it and let the intrinsic
default the abstract operand.

  $ wax -i wasm -f wax reinterp.wasm
  type t = fn() -> i64;
  type t_2 = fn() -> i32;
  type t_3 = fn() -> f32;
  type t_4 = fn() -> f64;
  #[export]
  fn f64nan() -> i64 {
      (nan:0x8000000000000).to_bits();
  }
  #[export]
  fn f32nan() -> i32 {
      (nan:0x400000 as f32).to_bits();
  }
  #[export]
  fn i32fb() -> f32 {
      (5).from_bits();
  }
  #[export]
  fn i64fb() -> f64 {
      (5 as i64).from_bits();
  }

Recompiling the decompiled Wax reproduces a valid module (the dropped casts are
recovered by the intrinsic's defaulting, the kept casts pin the other widths).

  $ wax -i wasm -f wax reinterp.wasm -o reinterp.wax
  $ wax -i wax -f wasm reinterp.wax -o out.wasm --validate
  $ wax -i wasm -f wat out.wasm --validate | grep -c reinterpret
  4

An integer-valued float constant decompiles to a bare integer literal (no cast),
so `to_bits` sees a `Number`/`LargeInt` receiver rather than a `Float`. Since
`to_bits` needs a float, it coerces that receiver to f64 (like a float binop
does), so the round-trip recompiles instead of being rejected. Regression: found
by the WAT-mutation fuzzer.

  $ printf 'fn f() -> i64 { (-4294967295).to_bits(); }\n' > tobits.wax
  $ wax -i wax -f wat tobits.wax
  (func $f (result i64) (i64.reinterpret_f64 (f64.const -4294967295)))

A *negative* integer-valued float constant must take the same integer-literal
path as a positive one: decompiling it as a `Float` node (rather than an `Int`)
would print integer-looking text that re-lexes as an integer on the round-trip,
dropping the `do f64` block annotation that pinned it to a float and leaving
`to_bits` applied to an `i64`. Here the value is even out of `i64` range, so the
block annotation is what carries the width. Regression: found by the
WAT-mutation fuzzer.

  $ cat > blk.wat <<'EOF'
  > (module (type (func (result i64)))
  >   (func (result i64)
  >     block (result f64) f64.const -18446744073709551615 end
  >     i64.reinterpret_f64))
  > EOF
  $ wax -i wat -f wax blk.wat -o blk.wax
  $ wax -i wax -f wasm blk.wax -o blk.wasm --validate
  $ wax -i wasm -f wat blk.wasm --validate | grep -c reinterpret
  1
