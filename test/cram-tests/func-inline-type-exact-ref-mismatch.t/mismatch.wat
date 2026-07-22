(module
  (type $s (struct))
  (type $ft (func (param (ref (exact $s))) (result i32)))
  (func (type $ft) (param (ref $s)) (result i32)
    unreachable))
