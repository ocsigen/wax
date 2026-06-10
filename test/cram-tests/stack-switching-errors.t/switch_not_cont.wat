(module
  (type $ft (func (param i32) (result i32)))
  (type $ct (cont $ft))
  (tag $e (result i32))
  (func $f (param $k (ref null $ct)) (result i32)
    (switch $ct $e (local.get $k))))
