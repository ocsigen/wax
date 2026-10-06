(module
  (@if $p (@then (@type $n i64)) (@else (@type $n (ref null $s))))
  (type $s (struct (field $f (mut (@type $n)))))
  (func $f (export "f") (param $x (@type $n)) (param $y (@type $n)) (param $c i32) (result (@type $n))
    (local $l (@type $n))
    (local.set $l (block (result (@type $n)) (local.get $x)))
    (select (result (@type $n)) (local.get $l) (local.get $y) (local.get $c))))
