(module
  (type $a (struct))
  (type $b (struct (field i32)))
  (table $ta 1 (ref null $a))
  (table $tb 1 (ref null $b))
  (func
    (table.copy $ta $tb (i32.const 0) (i32.const 0) (i32.const 0))))
