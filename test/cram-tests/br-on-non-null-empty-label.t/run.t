br_on_non_null branches with the operand's non-null reference on top of the
label's parameters, so the spec requires the target label to be [t* (ref ht)] —
its result must end in a reference type. Branching to a label with no result
type (here the enclosing function, whose result is empty) is invalid:

  $ wax check empty_label.wat
  Error:
    Type mismatch: br_on_non_null requires the target label to end in a
    reference type, but it has no result types.
   ──➤  empty_label.wat:5:5
  3 │   (func (param $r (ref null $t))
  4 │     local.get $r
  5 │     br_on_non_null 0
    ·     ^^^^^^^^^^^^^^^^
  6 │     unreachable))
  7 │ 
  [128]

A label that does end in a reference type is accepted:

  $ wax check ok.wat
