(module
  (func $v128_bitselect (result i32) (i32.const 0))
  (func $use (result v128)
    (v128.bitselect
      (v128.const i32x4 0 0 0 0)
      (v128.const i32x4 1 1 1 1)
      (v128.const i32x4 2 2 2 2)))
  (func $also (result i32) (call $v128_bitselect)))
