(module
  ;; a comment
  (@custom "foo" (; nested ;) "bar" (a (b)) ")" x")"y)
  (@"quoted id" 1 2)
  (global $g (@a) i32 (i32.const 1))
  (func $f (result i32)
    (@unknown 1 2 3)
    i32.const 42
  )
)
