(module
  (func $f (result f64 f64) unreachable)
  (func (export "g") (result i32 i32) call $f))
