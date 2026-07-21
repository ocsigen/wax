(module
  (type $t (struct))
  (func $f (param $y i32) (param $z (ref null $t))
    (local $x (ref null $t))
    (local.set $x
      (if (result (ref null $t)) (local.get $y)
        (then (if (result (ref null $t)) (local.get $y)
          (then (ref.null $t)) (else (ref.null $t))))
        (else (ref.null $t))))
    (local.set $x (local.get $z))))
