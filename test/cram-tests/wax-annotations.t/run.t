Annotations are validated: only known ones are accepted, their values must be
well-formed, and they may appear only where they are meaningful.

An unknown annotation is rejected:

  $ wax check unknown.wax
  Error: Unknown annotation 'inline'.
   ──➤  unknown.wax:1:1
  1 │ #[inline] fn f() {}
    · ^^^^^^^^^^^^^^^^^^^
  2 │ 
  [128]

The export annotation takes a string; inside an import block the name-only
import annotation also takes a string:

  $ wax check export-bad-value.wax
  Error: The export annotation expects a string.
   ──➤  export-bad-value.wax:1:12
  1 │ #[export = 5] fn f() {}
    ·            ^
  2 │ 
  [128]
  $ wax check import-bad-value.wax
  Error: The import annotation expects a string.
   ──➤  import-bad-value.wax:1:23
  1 │ import "m" #[import = 5] fn f();
    ·                       ^
  2 │ 
  [128]

The import annotation overrides an imported name, so it is meaningful only on an
import, not a definition:

  $ wax check import-on-definition.wax
  Error: The import annotation is not allowed here.
   ──➤  import-on-definition.wax:1:12
  1 │ #[import = "f"] fn f() {}
    ·            ^^^
  2 │ 
  [128]

An import can have at most one import-name annotation:

  $ wax check two-imports.wax
  Error: An import can have at most one import-name annotation.
   ──➤  two-imports.wax:1:39
  1 │ import "a" #[import = "b"] #[import = "c"] fn f();
    ·                                       ^^^
    ·                       ^^^ other import-name annotation here
  2 │ 
  [128]

A well-formed imported, re-exported declaration is accepted:

  $ wax check ok.wax
