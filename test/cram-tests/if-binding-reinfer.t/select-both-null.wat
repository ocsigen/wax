(module
  (type $t (struct))
  (func $f (param $c i32) (param $z (ref null $t))
    (local $x (ref null $t))
    (local.set $x (select (result (ref null $t)) (ref.null $t) (ref.null $t) (local.get $c)))
    (local.set $x (local.get $z))))
