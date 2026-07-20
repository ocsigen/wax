The `unused-field` and `unused-label` warnings, previously Wax-only, also run on
WebAssembly text/binary input via the validator.

A module-defined function or global that is never called, `ref.func`'d, read,
exported, or used as the start function is reported — unless its name starts with
`_`. A block label that is never branched to is reported too; a numeric `br N`
counts as a use of the frame N levels out, just like a named `br $l`.

This directory sets `WAX_WARN=correctness=hidden` (see the `dune` in the parent),
so re-enable the `unused` group explicitly:

  $ wax check -W unused=warning unused.wat
  Warning [unused-label]: The label '$unused_block' is never used.
    ──➤  unused.wat:10:12
   8 │   (func $main (export "main") (result i32) (call $helper))
   9 │   (func $labels (export "labels")
  10 │     (block $unused_block
     ·            ^^^^^^^^^^^^^
  11 │       (nop))
  12 │     (block $used_by_name
  Warning [unused-field]: The function '$unused_fn' is never used.
   ──➤  unused.wat:7:9
  5 │   (global $inline_exported (export "g") i32 (i32.const 4))
  6 │   (func $helper (result i32) (global.get $used))
  7 │   (func $unused_fn (result i32) (i32.const 0))
    ·         ^^^^^^^^^^
  8 │   (func $main (export "main") (result i32) (call $helper))
  9 │   (func $labels (export "labels")
  Warning [unused-field]: The global '$unused' is never used.
   ──➤  unused.wat:3:11
  1 │ (module
  2 │   (global $used i32 (i32.const 1))
  3 │   (global $unused i32 (i32.const 2))
    ·           ^^^^^^^
  4 │   (global $_ignored i32 (i32.const 3))
  5 │   (global $inline_exported (export "g") i32 (i32.const 4))
