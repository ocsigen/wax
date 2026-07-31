(module
  (type $ft (func (param i32) (result i32)))
  (func $a (param i32) (result i32) (local.get 0))
  (func (export "go") (param (ref null $ft) i32) (result i32)
    (@metadata.code.instr_freq (freq nan:0x0))
    (call_ref $ft (local.get 1) (local.get 0))))
