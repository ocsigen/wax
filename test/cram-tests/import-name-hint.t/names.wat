(module
  (import "env" "malloc" (func (param i32) (result i32)))
  (import "env" "counter" (global (mut i32)))
  (import "env" "memory" (memory 1))
  (import "env" "some.fn" (func))
  (func (export "loop") (result i32) i32.const 0))
