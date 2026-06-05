(module
  (func $f (result i32)
    (@if $debug
      (@then (call $log) (i32.const 1))
      (@else (i32.const 2))))
  (func $log))
