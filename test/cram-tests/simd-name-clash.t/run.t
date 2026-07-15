A free-function intrinsic is written as a qualified path ([v128::bitselect]),
so it can never clash with an ordinary name. A function named $v128_bitselect
therefore keeps its name when converting to wax: the real v128.bitselect
instruction decompiles to the [v128::bitselect] intrinsic, while the call to
the user function stays a plain call.

  $ wax clash.wat -f wax -o out.wax && cat out.wax
  fn v128_bitselect() -> i32 {
      0;
  }
  fn use() -> v128 {
      v128::bitselect(v128::i32x4(0, 0, 0, 0), v128::i32x4(1, 1, 1, 1), v128::i32x4(2, 2, 2, 2));
  }
  fn also() -> i32 {
      v128_bitselect();
  }

The wax still lowers back to a valid module (the intrinsic and the user
function stay distinct):

  $ wax out.wax -i wax -f wasm -o out.wasm --validate
