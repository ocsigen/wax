(module
  (type $ft (func (param i32) (result i32)))
  (func $a (param i32) (result i32) (local.get 0))
  (func (export "go") (param (ref null $ft) i32) (result i32)
    (@metadata.code.call_targets (target 0x1p1000000 0.73))
    (call_ref $ft (local.get 1) (local.get 0))))
