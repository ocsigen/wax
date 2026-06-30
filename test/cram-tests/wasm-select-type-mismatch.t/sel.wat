(module
  (func (param i32)
    (drop (select (i32.const 1) (i64.const 2) (local.get 0)))))
