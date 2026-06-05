(module
  (@if $debug
    (@then (func $a (result i32) (i32.const 1)))
    (@else (func $a (result i32) (i32.const 2))))
  (func $b (result i32) (call 0)))
