(module
  (func $g)
  (func $h)
  (elem declare funcref (ref.func $h))
  (func $f (result (ref func))
    (ref.func $g))
)
