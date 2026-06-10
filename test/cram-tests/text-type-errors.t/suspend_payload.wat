(module
  (type $t (struct))
  (tag $e (param (ref $t)) (result i32))
  (func (result i32)
    (suspend $e (i32.const 0))))
