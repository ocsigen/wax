A function that gives both a type reference [(type $t)] and an inline signature
that disagree in result arity is invalid. The result types were resolved from
the reference (via [typeuse]) but the result sources from the inline signature
(via [typeuse_functype]), so the two arrays differed in length and the exit
[pop_args] indexed the shorter one out of bounds (an uncaught exception). Now
both resolve the reference first, so it is rejected cleanly:

  $ wax check mismatch.wat
  Error:
    The inline function type does not match the type definition, whose
    parameters are '[]' and results are '[i32 i32]'.
   ──➤  mismatch.wat:3:15
  1 │ (module
  2 │   (type $t (func (result i32 i32)))
  3 │   (func (type $t) (result i32)
    ·               ^^
  4 │     unreachable))
  5 │ 
  [128]
