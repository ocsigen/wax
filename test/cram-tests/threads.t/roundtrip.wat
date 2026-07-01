(module
  (memory (export "mem") 1 1 shared)
  (func (export "l") (param i32) (result i32) (i32.atomic.load (local.get 0)))
  (func (export "s") (param i32 i64) (i64.atomic.store8 (local.get 0) (local.get 1)))
  (func (export "f") (atomic.fence)))
