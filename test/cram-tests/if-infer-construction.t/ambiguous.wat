(module
  (type $a (struct (field $x i32) (field $y i32)))
  (type $b (struct (field $x i32) (field $y i32)))
  (func $f (export "f") (param $c i32) (result i32)
    (struct.get $a $x
      (if (result (ref $a)) (local.get $c)
        (then (struct.new $a (i32.const 1) (i32.const 2)))
        (else (struct.new $a (i32.const 3) (i32.const 4)))))))
