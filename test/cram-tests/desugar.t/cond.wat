(module
  (func (export "f") (result i32)
    (@if $DEBUG (@then (i32.const 1)) (@else (i32.const 0)))))
