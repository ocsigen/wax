(module
  (func $f (param $n i32) (result i32)
    (local $used i32) (local $dead i32) (local i32) (local $_ignored i32)
    (local.set $used (local.get $n))
    (local.get $used)))
