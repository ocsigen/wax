(module
  (type $a (struct))
  (type $b (struct))
  (func $f1 (param (ref $a)))
  (func $f2 (param (ref $b)))
  (func
    (call $f1 (i32.const 0))))
