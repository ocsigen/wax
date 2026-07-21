(module
  (func $f (param $y i32)
    (local $x f32)
    (local.set $x
      (if (result f32) (local.get $y)
        (then (f32.const 1))
        (else (f32.const 2))))))
