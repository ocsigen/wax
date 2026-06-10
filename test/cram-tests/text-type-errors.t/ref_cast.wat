(module
  (type $point (struct (field i32)))
  (func (param (ref any)) (result i32)
    (ref.cast (ref $point) (local.get 0))))
