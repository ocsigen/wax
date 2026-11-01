(module
  (import "x" "f" (func $f (result i32)))
  (@if (not $wasi) (@then (export "g" (func $f))))
  (@if $use_js_string
    (@then (func (export "a") (result i32) (i32.const 0)))
    (@else (export "a" (func $b))))
  (func $b (result i32) (i32.const 1))
)
