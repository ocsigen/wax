(module
  (type $t (struct))
  (func $g (result (ref $t)) (unreachable))
  (func (result i32)
    (call $g)))
