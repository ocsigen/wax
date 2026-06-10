(module
  (func $callee (result i32 i32) (i32.const 1) (i32.const 2))
  (func $caller (result i32)
    (return_call $callee)))
