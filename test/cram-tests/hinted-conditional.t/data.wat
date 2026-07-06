(module
  (memory 1)
  (data (offset (@if $x (@then (i32.const 0)) (@else (f32.const 4)))) "x"))
