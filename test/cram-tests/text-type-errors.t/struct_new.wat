(module
  (type $point (struct (field i32)))
  (type $other (struct (field f64)))
  (func (result (ref $other))
    (struct.new_default $point)))
