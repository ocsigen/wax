(module
  (import "env"
    (item "a" (global $a i32))
    (item "b" (global $b i32)))
  (func (result i32) global.get $a global.get $b i32.add))
