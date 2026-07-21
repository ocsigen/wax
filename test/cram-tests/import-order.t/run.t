WebAssembly requires every import to precede all non-import definitions. The
main validation path enforces this, so the CLI rejects a misplaced import:

  $ wax --validate after_func.wat -o out.wat
  Error: This import is after a function definition.
   ──➤  after_func.wat:3:3
  1 │ (module
  2 │   (func $f)
    ·    ^^^^^^^^ first definition here
  3 │   (import "m" "g" (func $g)))
    ·   ^^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │ 
  [128]

A module whose imports come first validates cleanly:

  $ wax --validate ok.wat -o out.wat -f wat
