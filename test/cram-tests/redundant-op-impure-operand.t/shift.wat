(module
  (func $g (result i32) (i32.const 1))
  (func (export "f") (result i32)
    (i32.shr_s (call $g) (i32.const 0))))
