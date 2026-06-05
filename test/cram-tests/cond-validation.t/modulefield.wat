(module
  (@if $x
    (@then (func (result i32) (i32.const 1)))
    (@else (func (result i32) (f32.const 2)))))
