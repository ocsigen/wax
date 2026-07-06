(module
  (import "m" "used" (func $used (result i32)))
  (import "m" "dead" (func $dead (result i32)))
  (import "m" "_ignored" (global $_ignored i32))
  (func (export "main") (result i32) (call $used)))
