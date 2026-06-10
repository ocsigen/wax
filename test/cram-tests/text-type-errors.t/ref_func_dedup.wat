(module
  (type $a (func))
  (type $b (func))
  (func $f (type $b))
  (func (result i32)
    (ref.func $f)))
