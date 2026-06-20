(module
  (func $f (result i32)
    (block $x (result i32)
      (block $x (result i32) (br $x (i32.const 1))))))
