(module
  (type $ft (func (param i32) (result i32)))
  (type $ct (cont $ft))
  (func $g (param i32) (result i32) (local.get 0))
  (func (export "f") (param i32) (result i32)
    (resume $ct (local.get 0) (cont.new $ct (ref.func $g))))
  (elem declare func $g))
