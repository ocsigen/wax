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
  #[export = "f64nan"]
  fn f64nan() -> i64 {
      (nan:0x8000000000000).to_bits();
  }
  #[export = "f32nan"]
  fn f32nan() -> i32 {
      (nan:0x400000 as f32).to_bits();
  }
  #[export = "i32fb"]
  fn i32fb() -> f32 {
      (5).from_bits();
  }
  #[export = "i64fb"]
  fn i64fb() -> f64 {
      (5 as i64).from_bits();
  }

Recompiling the decompiled Wax reproduces a valid module (the dropped casts are
recovered by the intrinsic's defaulting, the kept casts pin the other widths).

  $ wax -i wasm -f wax reinterp.wasm -o reinterp.wax
  $ wax -i wax -f wasm reinterp.wax -o out.wasm --validate
  $ wax -i wasm -f wat out.wasm --validate | grep -c reinterpret
  4
