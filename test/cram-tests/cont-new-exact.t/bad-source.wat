(module
  (type $ft (func))
  (type $ct (cont $ft))
  (func $g)
  (func (export "f") (result i32)
    (cont.new $ct (ref.func $g)))
  (elem declare func $g))
