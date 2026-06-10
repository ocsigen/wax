(module
  (func $f (param i32) (result i32) (local.get 0))
  (func (result f64)
    (ref.func $f)))
