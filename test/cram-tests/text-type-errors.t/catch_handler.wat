(module
  (type $t (struct))
  (tag $e (param (ref $t)))
  (func
    (block $b (result i32)
      (try_table (catch $e $b))
      (return))
    (drop)))
