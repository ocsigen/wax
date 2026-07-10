(module
  (type $ft (func))
  (type $ct (cont $ft))
  (func $g)
  (global (export "c") (ref $ct) (cont.new $ct (ref.func $g)))
  (elem declare func $g))
