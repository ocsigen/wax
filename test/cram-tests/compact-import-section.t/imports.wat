(module
  (import "env" "a" (func))
  (import "env" "b" (func (param i32)))
  (import "env" "c" (global i32))
  (import "other" "x" (func))
  (import "env" "d" (memory 1)))
