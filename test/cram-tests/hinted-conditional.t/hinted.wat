(module
  (func (param i32) (result i32)
    local.get 0
    (@metadata.code.branch_hint "\01")
    if (result i32)
      (@if $x (@then (i32.const 1)) (@else (f32.const 2)))
    else
      i32.const 2
    end))
