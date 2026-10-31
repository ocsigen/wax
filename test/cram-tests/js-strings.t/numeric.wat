(module
  (import "env" "g" (global i32))
  (type $js (struct (field anyref)))
  (@string_imports "str")
  (@string_type $js)
  (global i32 (i32.const 7))
  (func (export "f") (result i32 (ref eq))
    (global.get 1)
    (@string "hello")))
