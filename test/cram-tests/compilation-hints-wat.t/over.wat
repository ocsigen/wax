(module
  (type $ft (func (result i32)))
  (func $a (result i32) (i32.const 1))
  (func $b (result i32) (i32.const 2))
  (table $t funcref (elem $a $b))
  (func (export "f") (result i32)
    (@metadata.code.call_targets (target $a 0.8) (target $b 0.5))
    (call_indirect $t (type $ft) (i32.const 0))))
