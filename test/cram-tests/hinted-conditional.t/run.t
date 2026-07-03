A conditional annotation can be nested inside a branch hint or an active
data/elem segment's offset expression. These positions were once skipped by the
walkers that detect and splice out conditionals, so the annotation survived to
validation and tripped an assertion. They are now explored per configuration
like any other conditional.

A conditional buried inside a branch-hinted `if` — the else branch is ill-typed
and is reported as reachable only when the condition is false:

  $ wax --validate hinted.wat -o out.wat
  Error: Type mismatch: this produces a value of type f32, but type i32
    is expected.
   ──➤  hinted.wat:6:45
  4 │     (@metadata.code.branch_hint "\01")
  5 │     if (result i32)
  6 │       (@if $x (@then (i32.const 1)) (@else (f32.const 2)))
    ·                                             ^^^^^^^^^^^
  7 │     else
  8 │       i32.const 2
  Hint: reachable when not $x
  [128]

A conditional in an active data segment's offset expression is likewise
validated in both configurations:

  $ wax --validate data.wat -o out.wat
  Error: Type mismatch: this produces a value of type f32, but type i32
    is expected.
   ──➤  data.wat:3:55
  1 │ (module
  2 │   (memory 1)
  3 │   (data (offset (@if $x (@then (i32.const 0)) (@else (f32.const 4)))) "x"))
    ·                                                       ^^^^^^^^^^^
  4 │ 
  Hint: reachable when not $x
  [128]
