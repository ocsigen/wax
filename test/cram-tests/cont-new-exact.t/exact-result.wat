(module
  (type $ft (func (param i32) (result i32)))
  (type $ct (cont $ft))
  (func $g (param i32) (result i32) (local.get 0))
  (func (export "f") (result (ref (exact $ct)))
    (cont.new $ct (ref.func $g)))
  (func (export "b") (param $c (ref $ct)) (result (ref (exact $ct)))
    (cont.bind $ct $ct (local.get $c)))
  (elem declare func $g))
