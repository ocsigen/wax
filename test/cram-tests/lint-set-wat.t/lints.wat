(module
  (type $pair (struct (field i32) (field i32)))
  (func $shift (param i32) (result i32)
    (i32.shl (local.get 0) (i32.const 40)))
  (func $divzero (param i32) (result i32)
    (i32.div_s (local.get 0) (i32.const 0)))
  (func $trunc (result i32)
    (i32.trunc_f64_s (f64.const 1e30)))
  (func $taut (param i32) (result i32)
    (i32.ge_u (local.get 0) (i32.const 0)))
  (func $self (param i32) (result i32)
    (i32.eq (local.get 0) (local.get 0)))
  (func $constcond (param i32) (result i32)
    (if (i32.const 0) (then (return (i32.const 1))))
    (local.get 0))
  (func $droppure
    (drop (i32.const 5)))
  (func $dropstruct
    (drop (struct.new $pair (i32.const 1) (i32.const 2))))
  (func $dead (result i32)
    (return (i32.const 1))
    (i32.const 2))
  (func $wide (param i64 i64)
    local.get 0
    local.get 1
    i64.mul_wide_s
    drop
    drop)
  (func $flat (param i32) (result i32)
    local.get 0
    i32.const 40
    i32.shl))
