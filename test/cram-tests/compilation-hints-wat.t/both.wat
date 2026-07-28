(module
  (func $f (param i32) (result i32)
    (@metadata.code.branch_hint "\01")
    (@metadata.code.instr_freq (freq 8))
    (if (result i32) (local.get 0) (then (i32.const 1)) (else (i32.const 2)))))
