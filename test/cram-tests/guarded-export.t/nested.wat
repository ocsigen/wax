(module
  (@if $a
    (@then
      (func $f (export "f") (param $v (ref eq)) (result (ref eq)) (local.get $v))
      (@if $b
        (@then (export "g" (func $f)))))))
