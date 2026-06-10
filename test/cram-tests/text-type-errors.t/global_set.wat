(module
  (type $t (struct))
  (global $g (mut (ref null $t)) (ref.null $t))
  (func
    (global.set $g (i32.const 0))))
