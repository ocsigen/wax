(module
  (@if (and $if (= $type "wasi"))
   (@then (global $g i32 (i32.const 0)))
   (@else (global $g i32 (i32.const 1))))
  (func (export "f") (result i32)
    (@if $loop
     (@then (return (i32.const 1))))
    (global.get $g)))
