(module
  (func $f (param $y i32) (param $z i64)
    (local $x i64)
    (local.set $x
      (if (result i64) (local.get $y)
        (then (i64.const 1))
        (else (local.get $z))))))
