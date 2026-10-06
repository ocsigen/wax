(module
  (@if $p
   (@then (global $g (mut i64) (i64.const 0)))
   (@else (global $g (mut i32) (i32.const 0))))
  (func (export "f") (drop (global.get $g))))
