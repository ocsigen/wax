(module
  (memory $m0 1)
  (memory $m1 1)
  (func (param i32) (result i32)
    (i32.load $m1 offset=8 (local.get 0))))
