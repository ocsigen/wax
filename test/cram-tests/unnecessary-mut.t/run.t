A global declared mutable but never assigned could be declared immutable. The
`unnecessary-mut` warning reports it, on both WebAssembly and Wax input.

Only a module-defined, non-exported global is flagged: an import's mutability is
part of the linking contract, and an exported mutable global may be assigned by
the host, so neither can be tightened. A name starting with `_` marks the
declaration as deliberately as-written, as it does for the `unused` warnings, and
a global that is not used at all is reported as `unused-field` instead — one
diagnostic per declaration, not two.

  $ wax check mut.wat
  Warning [unnecessary-mut]:
    The global '$never_set' is mutable but is never assigned.
   ──➤  mut.wat:3:11
  1 │ (module
  2 │   (import "env" "i" (global $imported (mut i32)))
  3 │   (global $never_set (mut i32) (i32.const 0))
    ·           ^^^^^^^^^^
  4 │   (global $set_somewhere (mut i32) (i32.const 0))
  5 │   (global $_ignored (mut i32) (i32.const 0))
  Hint: Drop the 'mut' to declare it immutable.

The Wax spelling of "immutable global" is `const` rather than a missing `mut`, so
the hint differs; everything else mirrors the validator:

  $ wax check mut.wax
  Warning [unnecessary-mut]:
    The global 'never_set' is mutable but is never assigned.
   ──➤  mut.wax:5:5
  3 │ }
  4 │ 
  5 │ let never_set: i32 = 0;
    ·     ^^^^^^^^^
  6 │ let set_somewhere: i32 = 0;
  7 │ let _ignored: i32 = 0;
  Hint: Declare it with 'const' instead of 'let'.

The warning belongs to the `redundant` group (the `mut` is what is redundant), so
that group's level applies to it:

  $ wax check -W redundant=hidden mut.wax
  $ wax check -W unnecessary-mut=error mut.wax
  Error [unnecessary-mut]:
    The global 'never_set' is mutable but is never assigned.
   ──➤  mut.wax:5:5
  3 │ }
  4 │ 
  5 │ let never_set: i32 = 0;
    ·     ^^^^^^^^^
  6 │ let set_somewhere: i32 = 0;
  7 │ let _ignored: i32 = 0;
  Hint: Declare it with 'const' instead of 'let'.
  [128]
