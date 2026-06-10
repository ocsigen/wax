(module
  (func $callee (result f64) (f64.const 1))
  (func $caller (result i32)
    (return_call $callee)))
