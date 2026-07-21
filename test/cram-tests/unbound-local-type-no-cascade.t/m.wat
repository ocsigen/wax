(module
  (type $ft (func (param i32) (result i32)))
  (func $g (type $ft) (local.get 0))
  (func (export "f") (result funcref)
    (local $r (ref null $missing))
    (ref.func $g)
    (local.set $r)
    (local.get $r)))
