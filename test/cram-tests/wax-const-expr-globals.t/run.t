A constant expression that reads a global is restricted by where it appears.
Tables are validated before the module's own globals, so a table initializer
may reference only an imported global; a global initializer, validated in order,
may reference a global declared before it.

A table initializer referencing a locally-defined global is rejected — at that
point only imported globals are in scope:

  $ wax check table-local-global.wax
  Error: The variable 'g' is not bound.
   ──➤  table-local-global.wax:2:24
  1 │ const g: &?func = null as &?func;
  2 │ table t: &?func [10] = g;
    ·                        ^
  3 │ 
  [128]

Referencing an imported global is fine:

  $ wax check table-imported-global.wax

A global initializer may reference an earlier global:

  $ wax check global-prev-global.wax
