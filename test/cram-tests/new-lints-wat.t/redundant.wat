(module
  (global $g (mut i32) (i32.const 0))
  (func (export "id") (param i32) (result i32) (i32.add (local.get 0) (i32.const 0)))
  (func (export "zero") (param i32) (result i32) (i32.mul (local.get 0) (i32.const 0)))
  (func (export "same") (param i32) (result i32) (i32.xor (local.get 0) (local.get 0)))
  (func (export "selfset") (param i32) (local.set 0 (local.get 0)))
  (func (export "gset") (global.set $g (global.get $g))))
