(module
  (func $f (param $x i32) (result i32)
    (local $outer i32)
    (local $inner i32)
    (local.set $outer
      (block $b (result i32)
        (local.set $inner (i32.add (local.get $x) (i32.const 1)))
        (i32.mul (local.get $inner) (local.get $inner))))
    (local.get $outer)))
