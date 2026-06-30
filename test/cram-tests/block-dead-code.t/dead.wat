(module
  (func $f (export "f") (result i32)
    (local $x i32)
    (local.set $x
      (i32.add (local.get $x)
        (block $l (result i32) (i32.ctz (br $l (i32.const 0x4))))))
    (local.get $x)))
