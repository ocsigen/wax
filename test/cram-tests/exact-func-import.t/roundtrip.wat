(module
  (type $ft (func (param i32) (result i64)))
  (import "env" "g" (func $g (exact (type $ft))))
  (global (ref (exact $ft)) (ref.func $g)))
