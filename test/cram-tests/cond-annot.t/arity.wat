(module
  (@if $wasi
    (@then (import "a" "g" (func $g (param i32 i32))))
    (@else (import "b" "g" (func $g (param i32)))))
  (func $h
    (@if $wasi
      (@then i32.const 1 i32.const 2 call $g)
      (@else i32.const 1 call $g))))
