(module
  (func $f (export "f") (param $n i32) (result i32)
    (loop $l (result i32)
      (br_if $l (local.get $n))
      (i32.const 9))))
