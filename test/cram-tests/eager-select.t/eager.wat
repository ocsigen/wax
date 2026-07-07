(module
  (func $div (export "div") (param $c i32) (param $x i32) (result i32)
    (select (i32.div_s (i32.const 1) (local.get $x))
            (i32.const 0)
            (local.get $c)))
  (func $pure (export "pure") (param $c i32) (param $x i32) (result i32)
    (select (i32.add (local.get $x) (i32.const 1))
            (i32.const 0)
            (local.get $c)))
  (func $unfolded (export "unfolded") (param $c i32) (param $x i32) (result i32)
    i32.const 1
    local.get $x
    i32.div_s
    i32.const 0
    local.get $c
    select))
