When a block, loop, or try instruction receives fewer stack arguments than
its declared block type parameters, the diagnostic error used to underline
the whole block construct; it now points at the first character of the block.

  $ cat > missing_block_arg.wat <<'WAT'
  > (module
  >   (func
  >     (i32.const 1)
  >     (block (param i32 i32))))
  > WAT
  $ wax check --error-format short missing_block_arg.wat
  missing_block_arg.wat:4:6: error: Type mismatch: expecting 2 argument(s) from the stack, but there are 1.
  missing_block_arg.wat:4:26: error: Type mismatch: unexpected values left on the stack: i32 i32
  [128]
