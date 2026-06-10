(module
  (type $t (struct))
  (tag $e (param (ref $t)))
  (func (result i32)
    (try (result i32)
      (do (i32.const 0))
      (catch $e (i32.add (i32.const 1))))))
