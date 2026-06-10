(module
  (rec
    (type $ft1 (func (param (ref null $ct2)) (result i32)))
    (type $ct1 (cont $ft1))
    (type $ft2 (func (param i32) (result i32)))
    (type $ct2 (cont $ft2)))
  (tag $e (param i32) (result i32))
  (func $sw (param $k (ref null $ct1)) (result i32)
    (switch $ct1 $e (local.get $k))))
