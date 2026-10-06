(module
  (type $s1 (sub (struct (field $f (mut i32)))))
  (type $s2 (sub $s1 (struct (field $a (mut i32)) (field $f i32))))
  (type $s3 (sub final $s2 (struct (field $b (mut i32)) (field $c i32))))
  (func (export "get") (param $x (ref $s2)) (result i32)
    (struct.get $s1 $f (local.get $x)))
  (func (export "set") (param $x (ref $s2))
    (struct.set $s1 $f (local.get $x) (i32.const 1)))
  (func (export "get3") (param $x (ref $s3)) (result i32)
    (i32.add
      (struct.get $s2 $f (local.get $x))
      (struct.get $s1 $f (local.get $x)))))
