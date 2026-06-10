(module
  (tag $e (param i32))
  (func $f
    (block $b (result i32)
      (try_table (catch_all $b))
      (return))
    (drop)))
