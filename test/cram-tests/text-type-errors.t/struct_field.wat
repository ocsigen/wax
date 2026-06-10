(module
  (type $inner (struct))
  (type $outer (struct (field (ref $inner))))
  (func (param (ref $outer)) (result i32)
    (struct.get $outer 0 (local.get 0))))
