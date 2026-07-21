(module
  (type $t (array i8))
  (func $f (param $c i32) (param $z (ref $t))
    (local $x (ref $t))
    (local.set $x
      (if (result (ref $t)) (local.get $c)
        (then (br 0 (array.new_fixed $t 1 (i32.const 1))))
        (else (local.get $z))))))
