(module
  (memory 1)
  (global $g (mut i32) (i32.const 0))
  (data (offset (i32.add (i32.const 0) (i32.const 42))) "x")
  (func (export "f") (result i32) (global.get $g)))
