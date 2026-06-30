(module
  (func $f (export "f") (param $c i32) (result i32)
    (i32.add (i32.const 0)
      (block $b (result i32)
        (if (local.get $c) (then (br $b (i32.const 5))))
        (i32.const 7)))))
