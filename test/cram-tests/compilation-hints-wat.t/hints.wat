(module
  (type $ft (func (param i32) (result i32)))
  (func $a (param i32) (result i32) (local.get 0))
  (func $b (param i32) (result i32) (i32.const 7))
  (table $t funcref (elem $a $b))
  (func (export "go") (param i32) (result i32)
    ;; A comment before the hints stays put: an annotation payload is not a
    ;; trivia anchor, so it cannot be pulled inside one of the groups below.
    (@metadata.code.instr_freq (freq 16))
    (@metadata.code.call_targets (target $a 0.73) (target $b 0.21))
    (call_indirect $t (type $ft) (local.get 0) (local.get 0))))
