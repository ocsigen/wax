Three lints that also run on WebAssembly input, via the validator.

`unused-import` (in the `unused` group) reports an imported function or global
that is never referenced, exported, or used as the start function — the import
analog of `unused-field`. A name starting with `_` is intentionally unused.

  $ wax check -W unused=warning imports.wat
  Warning: The imported function '$dead' is never used.
   ──➤  imports.wat:3:28
  1 │ (module
  2 │   (import "m" "used" (func $used (result i32)))
  3 │   (import "m" "dead" (func $dead (result i32)))
    ·                            ^^^^^
  4 │   (import "m" "_ignored" (global $_ignored i32))
  5 │   (func (export "main") (result i32) (call $used)))

`redundant-operation` (its own group, off by default) reports an operation with
no effect on its result, one whose result is a constant regardless of the
variable operand, or a self-assignment.

  $ wax check -W redundant=warning redundant.wat
  Warning: This operation has no effect on its result.
   ──➤  redundant.wat:3:49
  1 │ (module
  2 │   (global $g (mut i32) (i32.const 0))
  3 │   (func (export "id") (param i32) (result i32) (i32.add (local.get 0) (i32.const 0)))
    ·                                                 ^^^^^^^
  4 │   (func (export "zero") (param i32) (result i32) (i32.mul (local.get 0) (i32.const 0)))
  5 │   (func (export "same") (param i32) (result i32) (i32.xor (local.get 0) (local.get 0)))
  Warning: This operation always yields 0.
   ──➤  redundant.wat:4:51
  2 │   (global $g (mut i32) (i32.const 0))
  3 │   (func (export "id") (param i32) (result i32) (i32.add (local.get 0) (i32.const 0)))
  4 │   (func (export "zero") (param i32) (result i32) (i32.mul (local.get 0) (i32.const 0)))
    ·                                                   ^^^^^^^
  5 │   (func (export "same") (param i32) (result i32) (i32.xor (local.get 0) (local.get 0)))
  6 │   (func (export "selfset") (param i32) (local.set 0 (local.get 0)))
  Warning: This operation always yields 0.
   ──➤  redundant.wat:5:51
  3 │   (func (export "id") (param i32) (result i32) (i32.add (local.get 0) (i32.const 0)))
  4 │   (func (export "zero") (param i32) (result i32) (i32.mul (local.get 0) (i32.const 0)))
  5 │   (func (export "same") (param i32) (result i32) (i32.xor (local.get 0) (local.get 0)))
    ·                                                   ^^^^^^^
  6 │   (func (export "selfset") (param i32) (local.set 0 (local.get 0)))
  7 │   (func (export "gset") (global.set $g (global.get $g))))
  Warning: This assignment writes the local back to itself.
   ──➤  redundant.wat:6:41
  4 │   (func (export "zero") (param i32) (result i32) (i32.mul (local.get 0) (i32.const 0)))
  5 │   (func (export "same") (param i32) (result i32) (i32.xor (local.get 0) (local.get 0)))
  6 │   (func (export "selfset") (param i32) (local.set 0 (local.get 0)))
    ·                                         ^^^^^^^^^^^
  7 │   (func (export "gset") (global.set $g (global.get $g))))
  8 │ 
  Warning: This assignment writes the global back to itself.
   ──➤  redundant.wat:7:26
  5 │   (func (export "same") (param i32) (result i32) (i32.xor (local.get 0) (local.get 0)))
  6 │   (func (export "selfset") (param i32) (local.set 0 (local.get 0)))
  7 │   (func (export "gset") (global.set $g (global.get $g))))
    ·                          ^^^^^^^^^^^^^
  8 │ 

`cast-always-fails` (in `correctness`, shown by default) reports a `ref.cast` /
`ref.test` whose operand can never have the target type (the two are unrelated
under single-inheritance subtyping). A redundant cast to a type the operand
already has is a `redundant-operation` instead; a proper downcast is fine.

  $ wax check -W redundant=warning casts.wat
  Warning: This cast is redundant: the value already has this type.
   ──➤  casts.wat:6:6
  4 │   (type $C (sub $A (struct (field i32) (field i32))))
  5 │   (func (export "redundant") (param (ref $A)) (result (ref $A))
  6 │     (ref.cast (ref $A) (local.get 0)))
    ·      ^^^^^^^^^^^^^^^^^
  7 │   (func (export "downcast") (param (ref $A)) (result (ref $C))
  8 │     (ref.cast (ref $C) (local.get 0)))
