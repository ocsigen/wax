(module
  (type $t (struct))
  (func (param (ref null $t)) (result i32)
    (ref.as_non_null (local.get 0))))
