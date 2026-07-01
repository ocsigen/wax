Converting a Wat module whose index or label reference resolves to nothing (out
of range, or naming an undeclared entity) reports a located diagnostic and
aborts, rather than crashing with an uncaught exception. A text input is
validated before it is converted to a different format, so validation reports
the unresolved reference here (the decompiler keeps its own backstop for the
same class on the trusted binary-input path).

A branch to a label depth that is not in scope:

  $ wax -i wat -f wax unresolved_label.wat
  Error: Unknown label: 10 is not bound.
   ──➤  unresolved_label.wat:1:18
  1 │ (module (func br 10))
    ·                  ^^
  2 │ 
  [128]

A call to a function index that is out of range:

  $ wax -i wat -f wax unresolved_index.wat
  Error: Unknown function: index 99 is not bound.
   ──➤  unresolved_index.wat:1:20
  1 │ (module (func call 99))
    ·                    ^^
  2 │ 
  [128]
