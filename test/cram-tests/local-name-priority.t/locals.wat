(module
  (func $f (export "f") (result i32)
    (local i32) (local $x i32)
    (local.set 0 (i32.const 1))
    (local.set $x (i32.const 2))
    (i32.add (local.get 0) (local.get $x))))
