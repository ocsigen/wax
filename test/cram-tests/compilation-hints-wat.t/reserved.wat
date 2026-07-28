(module
  (func $f (param i32)
    (@metadata.code.instr_freq (never_opt))
    (loop $l
      (@metadata.code.instr_freq (always_opt))
      (br_if $l (local.get 0)))))
