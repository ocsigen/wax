(module
  (func (param i32) (result i32)
    (@metadata.code.branch_hint "\00")
    (if (result i32) (local.get 0)
      (then (i32.const 1))
      (else (i32.const 2)))))
