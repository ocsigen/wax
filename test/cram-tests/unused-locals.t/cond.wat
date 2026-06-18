(module
  (func $f (param $n i32) (result i32)
    (local $used_when_wasi i32) (local $never_used i32)
    (local.set $used_when_wasi (local.get $n))
    (@if $wasi
      (@then (local.get $used_when_wasi))
      (@else (i32.const 0)))))
