(module
  (type $t (struct))
  (func (result i32)
    (block $b (result (ref $t))
      (br $b (i32.const 0)))
    (drop)
    (i32.const 0)))
