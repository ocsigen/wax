(module
  (type $vec (array f32))
  (func (result (ref $vec))
    f32.const 1
    array.new_fixed $vec 4294967295))
