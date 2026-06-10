(module
  (type $ft0 (func (param i32) (result i32)))
  (type $ct0 (cont $ft0))
  (type $ft1 (func (param f64) (result i32)))
  (type $ct1 (cont $ft1))
  (func $f (param $k (ref null $ct0)) (result (ref $ct1))
    (cont.bind $ct0 $ct1 (local.get $k))))
