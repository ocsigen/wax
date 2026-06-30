A block whose trailing value is a nested block infers its result in synthesis
position too: the nested block's value flows out as the outer block's result
(each block gets the inferred `i32`):

  $ wax nested.wax -f wat
  ;; A block whose trailing value is itself a nested block, in synthesis position
  ;; (no expected type from the context): the inner block runs its own inference
  ;; and its value becomes the outer block's value.
  (func $h (param $c i32) (result i32)
    (local $a i32) (local $b i32) (local $d i32)
    (local.set $a (block (result i32) (block (result i32) (i32.const 5))))
    (local.set $b
      (block (result i32)
        (if (result i32) (local.get $c)
          (then (i32.const 5))
          (else (i32.const 7)))))
    (local.set $d (loop (result i32) (block (result i32) (i32.const 9))))
    (i32.add (i32.add (local.get $a) (local.get $b)) (local.get $d))
  )
