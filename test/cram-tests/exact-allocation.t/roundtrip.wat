(module
  (type $point (struct (field i32) (field i32)))
  (func (export "g") (result (ref $point))
    (struct.new $point (i32.const 1) (i32.const 2))))
