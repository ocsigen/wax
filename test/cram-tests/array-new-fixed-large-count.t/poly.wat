(module
  (type $vec (array f32))
  (func (result (ref $vec))
    unreachable
    array.new_fixed $vec 4294967295))
