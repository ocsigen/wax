(module
  (func $f)
  (func (export "g") (ref.func $f) (drop)))
