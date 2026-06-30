(module
  (type $t (func))
  (memory 1)
  (data "a") (data "bbbb")
  (table 2 funcref)
  (elem func) (elem func $f)
  (func $f)
  (func
    (memory.init 0 1 (i32.const 0) (i32.const 0) (i32.const 0))
    (table.init 0 1 (i32.const 0) (i32.const 0) (i32.const 0))
    (call_indirect 0 (type $t) (i32.const 0))))
