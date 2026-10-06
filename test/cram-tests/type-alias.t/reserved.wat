(module
  (@type $i8 i32)
  (type $s (struct (field $f (mut (@type $i8)))))
  (func $mk (export "mk") (param $x i32) (result (ref $s))
    (struct.new $s (local.get $x)))
)
