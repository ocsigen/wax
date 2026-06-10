(module
  (tag $e (param i32))
  (func $f
    (block $b (result f64)
      (try_table (catch $e $b))
      (return))
    (drop)))
