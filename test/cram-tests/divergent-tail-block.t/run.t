A block that ends another one and never completes, its value going to an
enclosing label, takes the result of the block it ends, as it does from a
concrete context (an operand of resume, suspend or cont.bind; see
resume-operand-inferred-block.t). It was rejected as a call argument, a
binding's initializer or a function's value ("expecting 1 returned value(s)
from the stack, but there are 0"), the enclosing block's result being then
inferred; so were blocks nested deeper.

  $ wax -f wat tails.wax
  (tag $e)
  (tag $e1 (param i32))
  (func $g (param $x (ref exn)))
  (func $h (param $x i32))
  (func $arg
    (call $g
      (block $h (result (ref exn))
        (try_table (result (ref exn)) (catch_ref $e $h) (throw $e))))
  )
  (func $binding (result (ref exn))
    (local $x (ref exn))
    (local.set $x
      (block $h (result (ref exn))
        (try_table (result (ref exn)) (catch_ref $e $h) (throw $e))))
    (local.get $x)
  )
  (func $value (result i32)
    (block $h (result i32)
      (try_table (result i32) (catch $e1 $h) (throw $e1 (i32.const 1))))
  )
  (func $nested
    (call $h (block $h (result i32) (block (result i32) (br $h (i32.const 1)))))
  )
  (func $deeper (param $c i32) (result i32)
    (block $h (result i32)
      (if (result i32) (local.get $c)
        (then
          (block $g (result i32) (block (result i32) (br $h (i32.const 1)))))
        (else (i32.const 2))))
  )
  (func $looping (result i32)
    (block $h (result i32) (loop (result i32) (br $h (i32.const 1))))
  )

The lowered module validates.

  $ wax -f wasm tails.wax -o tails.wasm && wax -v -f wat tails.wasm > /dev/null && echo ok
  ok
