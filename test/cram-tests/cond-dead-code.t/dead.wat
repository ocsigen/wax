(module
  (func $after_return (export "after_return") (result i32)
    (return (i32.const 1))
    (@if $p (@then (return (i32.const 2))) (@else (return (i32.const 3)))))
  (func $after_conditional (export "after_conditional") (result i32)
    (@if $p (@then (return (i32.const 1))) (@else (return (i32.const 2))))
    (@if $p (@then (return (i32.const 3))) (@else (return (i32.const 4))))))
