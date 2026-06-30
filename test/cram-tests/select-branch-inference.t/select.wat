(module
  (type $s (sub (struct (field i32))))
  (type $t (sub (struct (field i32))))
  (func $g (param (ref $s)) (result i32) (i32.const 0))
  (func $arg (param $c i32) (result i32)
    (call $g
      (select (result (ref $s))
        (struct.new $s (i32.const 1))
        (struct.new $s (i32.const 2))
        (local.get $c))))
  (func $bound (param $c i32) (result (ref $s))
    (local $x (ref $s))
    (local.set $x
      (select (result (ref $s))
        (struct.new $s (i32.const 3))
        (struct.new $s (i32.const 4))
        (local.get $c)))
    (local.get $x)))
