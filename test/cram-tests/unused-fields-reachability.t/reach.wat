(module
  (memory $dead_mem 1)
  (global $dead_g (mut i32) (i32.const 0))
  (tag $dead_tag (param i32))
  (table $t 1 funcref)
  (elem (table $t) (i32.const 0) funcref (ref.func $rooted_by_elem))

  ;; dead cycle, plus a helper only the cycle reaches
  (func $a (result i32) (call $b))
  (func $b (result i32) (call $helper_of_dead))
  (func $helper_of_dead (result i32)
    (global.set $dead_g (memory.size $dead_mem))
    (call $a))

  ;; self-recursive and dead
  (func $selfrec (result i32) (call $selfrec))

  ;; live chain from an export
  (func $live_leaf (result i32) (i32.const 1))
  (func $live (export "live") (result i32) (call $live_leaf))

  ;; reachable only through the element segment
  (func $rooted_by_elem (result i32) (i32.const 2)))
