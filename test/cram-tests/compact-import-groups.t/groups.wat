(module
  (import "env"
    (item "a" (func (result i32)))
    (item "b" (global i32)))
  (import "env"
    (item "x")
    (item "y")
    (func (param i32))))
