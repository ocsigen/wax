(module
  ;; The inner then-branch requires $ver < 1.0.0 while the outer branch already
  ;; assumes $ver >= 5.0.0, so the ill-typed (f32.const 1) is unreachable.
  (func (result i32)
    (@if (>= $ver (5 0 0))
      (@then
        (@if (< $ver (1 0 0))
          (@then (f32.const 1))
          (@else (i32.const 2))))
      (@else (i32.const 3)))))
