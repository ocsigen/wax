(module
  (type $ft (func (param i32) (result i32)))
  (func $a (param i32) (result i32) (local.get 0))
  (func (export "go") (param $f (ref null $ft)) (param i32) (result i32)
    (@metadata.code.instr_freq (freq 8))
    (@metadata.code.call_targets (target $a 1))
    (call_ref $ft (local.get 1) (local.get $f))))
