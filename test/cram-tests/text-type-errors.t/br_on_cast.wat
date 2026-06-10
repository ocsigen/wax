(module
  (type $t (struct))
  (func (result i32)
    (block $b (result (ref $t))
      (br_on_cast $b (ref $t) (ref $t) (i32.const 0))
      (unreachable))
    (drop)
    (i32.const 0)))
