(module
  (tag $e)
  (func $f (export "f") (result i32)
    (block $h
      (return (try_table (result i32) (catch_all $h) (i32.const 5))))
    (i32.const 7)))
