Path-sensitive validation of conditional annotations. Each error is reported
once, annotated with the minimal assumption under which it is reachable.

An error confined to the else branch is reachable only when the condition is
false:

  $ wax --validate else_error.wat -o out.wat
  Error: Type mismatch: this instruction expects type i32
    but the stack has type f32
   ──➤  else_error.wat:5:15
  3 │     (@if $x
  4 │       (@then (i32.const 1))
  5 │       (@else (f32.const 2)))))
    ·               ^^^^^^^^^^^
  6 │ 
  Hint: reachable when not $x
  [128]

The same holds at the module-field level:

  $ wax --validate modulefield.wat -o out.wat
  Error: Type mismatch: this instruction expects type i32
    but the stack has type f32
   ──➤  modulefield.wat:4:32
  2 │   (@if $x
  3 │     (@then (func (result i32) (i32.const 1)))
  4 │     (@else (func (result i32) (f32.const 2)))))
    ·                                ^^^^^^^^^^^
  5 │ 
  Hint: reachable when not $x
  [128]

An error whose occurrence depends on a different (sibling) conditional reports
the full assumption — here the stack underflows only when $d is false:

  $ wax --validate sibling.wat -o out.wat
  Error: Type mismatch: the stack is empty (a value is missing).
   ──➤  sibling.wat:7:6
  5 │     (i32.const 0)
  6 │     (@if $d (@then (i32.const 0)))
  7 │     (i32.add)))
    ·      ^^^^^^^
  8 │ 
  Hint: reachable when not $d
  [128]

An infeasible branch combination is pruned, so its ill-typed code raises no
error:

  $ wax --validate infeasible.wat -o out.wat

A condition that cannot be modeled is reported:

  $ wax --validate illformed.wat -o out.wat
  Error: This comparison in a condition is not supported.
   ──➤  illformed.wat:2:9
  1 │ (module
  2 │   (func (@if (< $a $b) (@then (nop)))))
    ·         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  3 │ 
  [128]
