(module
  ;; An inline function-import signature synthesises an implicit type (index 0).
  (import "env" "f" (func $f (param i32) (result i64)))
  ;; Referencing that implicit type from a ref-type position: Wax has no inline
  ;; function-type form here, so it is given a name and a `type` declaration.
  (global (mut (ref null 0)) (ref.null 0)))
