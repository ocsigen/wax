(module
  (func (param i32) (result i32)
    (block $a (result i32)
      (block $b
        (i32.const 1)
        (br_table $b $a (local.get 0)))
      (i32.const 2))))
