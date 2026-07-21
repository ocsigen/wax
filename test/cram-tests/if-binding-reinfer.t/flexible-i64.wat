(module
  (func $f (param $y i32)
    (local $x i64)
    (local.set $x
      (if (result i64) (local.get $y)
        (then (i64.const 1))
        (else (i64.const 2))))))
