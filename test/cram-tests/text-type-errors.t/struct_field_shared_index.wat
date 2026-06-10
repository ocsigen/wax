(module
  (type $x (struct))
  (type $y (struct))
  (type $a (struct (field (ref $x))))
  (type $b (struct (field (ref $y))))
  (func (param (ref $a)) (result i32)
    (struct.get $a 0 (local.get 0))))
