(module
  (type $t (struct))
  (type $ft (func))
  (table $tb 1 (ref null $t))
  (func
    (call_indirect $tb (type $ft) (i32.const 0))))
