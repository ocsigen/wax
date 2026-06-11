A module entity whose name collides with a SIMD intrinsic (here a function
named $v128_bitselect) is renamed when converting to wax, so the real
v128.bitselect instruction still lowers to the intrinsic rather than a call to
the user function. The call site is rewritten to the renamed function.

  $ wax clash.wat -f wax -o out.wax && cat out.wax
  fn v128_bitselect_2() -> i32 {
      0;
  }
  fn use() -> v128 {
      v128_bitselect(
          v128_const_i32x4(0, 0, 0, 0),
          v128_const_i32x4(1, 1, 1, 1),
          v128_const_i32x4(2, 2, 2, 2),
      );
  }
  fn also() -> i32 {
      v128_bitselect_2();
  }

The renamed wax still lowers back to a valid module (the intrinsic and the
user function stay distinct):

  $ wax out.wax -i wax -f wasm -o out.wasm --validate
