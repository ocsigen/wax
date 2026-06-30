(module
  (type $point (struct (field $x i32) (field $y i32)))
  (func $f (export "f") (param $c i32) (result i32)
    (struct.get $point $x
      (if (result (ref $point)) (local.get $c)
        (then (struct.new $point (i32.const 1) (i32.const 2)))
        (else (struct.new $point (i32.const 3) (i32.const 4)))))))
