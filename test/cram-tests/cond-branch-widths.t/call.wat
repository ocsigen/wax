(module
  (@if $p
   (@then (import "n" "v" (func $v (param (ref eq)) (result i64))))
   (@else (import "n" "v" (func $v (param (ref eq)) (result i32)))))
  (func $succ (export "succ") (param $x (ref eq)) (result i32)
    (drop (call $v (local.get $x)))
    (i32.const 0)))
