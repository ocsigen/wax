(module
  (import "env"
    (item $a "a")
    (item $b "b")
    (global i32))
  (func (result i32) global.get $a global.get $b i32.add))
