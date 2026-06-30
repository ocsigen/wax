(module
  (func (export "f") (param $c i32) (result i32)
    (if (result i32) (local.get $c) (then (i32.const 1)) (else (i32.const 2)))))
