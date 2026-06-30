Decompiling a Wasm module whose index or label reference resolves to nothing
(out of range, or naming an undeclared entity) reports a located diagnostic and
aborts, rather than crashing with an uncaught exception.

A branch to a label depth that is not in scope:

  $ wax -i wat -f wax unresolved_label.wat
  Error:
    This reference resolves to nothing: it is out of range or names an undeclared entity.
   ──➤  unresolved_label.wat:1:18
  1 │ (module (func br 10))
    ·                  ^^
  2 │ 
  [128]

A call to a function index that is out of range:

  $ wax -i wat -f wax unresolved_index.wat
  Error:
    This reference resolves to nothing: it is out of range or names an undeclared entity.
   ──➤  unresolved_index.wat:1:20
  1 │ (module (func call 99))
    ·                    ^^
  2 │ 
  [128]
