(module
  (@if (>= $ocaml_version (5 1 0))
    (@then (global $size i32 (i32.const 16)))
    (@else (global $size i32 (i32.const 20))))
  (func $get (result i32) (global.get $size)))
