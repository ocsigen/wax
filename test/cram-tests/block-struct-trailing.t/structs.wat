(module
  (type $point (struct (field i32) (field i32)))
  (type $pair (struct (field i32) (field i32)))
  (type $vec3 (struct (field i32) (field i32) (field i32)))
  (func $unique (export "unique") (param $a i32) (result (ref $vec3))
    (local $x (ref $vec3))
    (local.set $x
      (block (result (ref $vec3))
        (struct.new $vec3 (local.get $a) (local.get $a) (local.get $a))))
    (local.get $x))
  (func $ambiguous (export "ambiguous") (param $a i32) (result (ref $point))
    (local $x (ref $point))
    (local.set $x
      (block (result (ref $point))
        (struct.new $point (local.get $a) (local.get $a))))
    (local.get $x)))
