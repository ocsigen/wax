(module
  (type $t (array i8))
  (func $f (param $y i32) (param $z (ref null $t))
    (local $x (ref null $t))
    (local.set $x
      (if (result (ref null $t)) (local.get $y)
        (then
          (if (result (ref null $t)) (local.get $y)
            (then (array.new_fixed $t 1 (i32.const 1)))
            (else (array.new_fixed $t 1 (i32.const 2)))))
        (else (local.get $z))))))
