Folding a block or loop with stack parameters must leave the operand-producing
instructions in place (they cannot be folded into the block's parentheses) and
must not duplicate them. Regression test: `consume` once re-walked the folded
stack head, emitting each consumed operand multiple times.

  $ wax --fold block-params.wat -f wat -o out.wat && cat out.wat
  (func $block (result i32)
    (i32.const 1)
    (i32.const 2)
    (block (param i32 i32) (result i32) (i32.add))
  )
  (func $loop (result i32)
    (i32.const 10)
    (i32.const 20)
    (i32.const 30)
    (loop (param i32 i32 i32) (result i32) (i32.add (i32.add)))
  )
