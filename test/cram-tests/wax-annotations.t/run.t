Annotations are validated: only known ones are accepted, their values must be
well-formed, they may appear only where they are meaningful, and a body-less
declaration must be imported.

An unknown annotation is rejected:

  $ wax check unknown.wax
  Error: Unknown annotation "inline".
   ──➤  unknown.wax:1:1
  1 │ #[inline] fn f() {}
    · ^^^^^^^^^^^^^^^^^^^
  2 │ 
  [123]

The export annotation takes a string; the import annotation takes a module and
name:

  $ wax check export-bad-value.wax
  Error: The export annotation expects a string.
   ──➤  export-bad-value.wax:1:12
  1 │ #[export = 5] fn f() {}
    ·            ^
  2 │ 
  [123]
  $ wax check import-bad-value.wax
  Error: The import annotation expects a module and name, e.g. ("env", "f").
   ──➤  import-bad-value.wax:1:12
  1 │ #[import = "env"] fn f();
    ·            ^^^^^
  2 │ 
  [123]

import is for declarations, not definitions:

  $ wax check import-on-definition.wax
  Error: The import annotation is not allowed here.
   ──➤  import-on-definition.wax:1:12
  1 │ #[import = ("e", "f")] fn f() {}
    ·            ^^^^^^^^^^
  2 │ 
  [123]

A function (or global) declaration with no body needs an import:

  $ wax check decl-no-import.wax
  Error: This declaration has no definition; it needs an import annotation.
   ──➤  decl-no-import.wax:1:1
  1 │ fn f();
    · ^^^^^^^
  2 │ 
  [123]

A well-formed imported, re-exported declaration is accepted:

  $ wax check ok.wax
