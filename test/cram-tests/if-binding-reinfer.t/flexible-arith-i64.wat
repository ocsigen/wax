(module
  (func $f (param $y i32)
    (local $x i64)
    (local.set $x
      (if (result i64) (local.get $y)
        (then (i64.add (i64.const 1) (i64.const 2)))
        (else (i64.const 2))))))
