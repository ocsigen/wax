(module
  (type $t (func (param i32)))
  (func $f (result f64) (f64.const 0))  ;; mints the implicit type at index 1
  (table funcref (elem $f))
  ;; call_indirect referencing the implicit type by its numeric index
  (func (export "run") (result f64)
    (call_indirect (type 1) (i32.const 0))
  )
)
