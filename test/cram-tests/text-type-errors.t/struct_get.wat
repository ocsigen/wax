(module
  (type $point (struct (field i32)))
  (func (result i32)
    (struct.get $point 0 (i32.const 0))))
