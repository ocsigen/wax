(module
  ;; The extra value is pushed only when $d holds, but i32.add always consumes
  ;; two, so the stack underflows exactly when $d is false.
  (func (result i32)
    (i32.const 0)
    (@if $d (@then (i32.const 0)))
    (i32.add)))
