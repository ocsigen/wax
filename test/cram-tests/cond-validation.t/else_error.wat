(module
  (func (result i32)
    (@if $x
      (@then (i32.const 1))
      (@else (f32.const 2)))))
