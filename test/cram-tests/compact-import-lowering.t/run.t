With `-X compact-import-section` (or the module's own `#![feature = "…"]`
declaration), a Wax `import "m" { … }` block lowers to one compact import-section
entry. This is authorial: the encoder groups exactly what the block groups, and
never coalesces imports the source left separate.

A block whose items have differing import types becomes a `Group1` — one type
per `(item …)`:

  $ wax het.wax -f wat
  (@feature "compact-import-section")
  (import "env"
    (item "a" (func $a))
    (item "b" (func $b (param i32)))
    (item "c" (global $c i32))
  )

A block whose items all share one import type becomes the compacter `Group2` —
a single shared type, name-only items (the ids ride the binary name section):

  $ wax homo.wax -f wat
  (@feature "compact-import-section")
  (import "env" (item $a "a") (item $b "b") (item $c "c") (func (param i32)))

A one-item block cannot round-trip as a group (a Wax block re-forms only from
≥2 imports), so it flattens to a plain import:

  $ wax singleton.wax -f wat
  (@feature "compact-import-section")
  (import "env" "a" (func $a (param i32)))

Two adjacent but *separate* `import "m" …;` statements are not a block, so they
stay two individual imports even with the feature on — the source did not group
them:

  $ wax separate.wax -f wat
  (@feature "compact-import-section")
  (import "env" "a" (func $a (param i32)))
  (import "env" "b" (func $b (param i32)))

Without the feature, `import "m" { … }` is still core Wax syntax; it compiles by
flattening the block to individual imports:

  $ wax plainblock.wax -f wat
  (import "env" "a" (func $a (param i32)))
  (import "env" "b" (func $b (param i32)))

Inline `#[export]` attributes on block items become standalone `(export …)`
fields (a compact group has no inline-export slot), emitted after the group; the
indices resolve to the right imports through a binary round-trip:

  $ wax exp.wax -f wat
  (@feature "compact-import-section")
  (import "env" (item $a "a") (item $b "b") (item $c "c") (func (param i32)))
  (export "a" (func $a))
  (export "cc" (func $c))

  $ wax exp.wax -f wasm -o exp.wasm
  $ wax exp.wasm -f wat
  (@feature "compact-import-section")
  (type (func (param i32)))
  (import "env" (item $a "a") (item $b "b") (item $c "c") (func (param i32)))
  (export "a" (func $a))
  (export "cc" (func $c))

The blocks survive a binary round-trip unchanged (Wax → WASM → Wax), reproducing
the `Group1` and `Group2` forms:

  $ wax het.wax -f wasm -o het.wasm
  $ wax het.wasm -f wax
  #![feature = "compact-import-section"]
  type t = fn();
  type t_2 = fn(i32);
  import "env" {
      fn a();
      fn b(i32);
      const c: i32;
  }

  $ wax homo.wax -f wasm -o homo.wasm
  $ wax homo.wasm -f wax
  #![feature = "compact-import-section"]
  type t = fn(i32);
  import "env" {
      fn a(i32);
      fn b(i32);
      fn c(i32);
  }

A WAT explicit group followed by same-module singles preserves both: the group
stays a group, and the trailing `env` singles are not coalesced onto it:

  $ cat > mixed.wat <<'WAT'
  > (module
  >   (import "env" (item "a" (func)) (item "b" (func (param i32))))
  >   (import "env" "c" (global i32))
  >   (import "env" "d" (global i64)))
  > WAT
  $ wax -X compact-import-section mixed.wat -f wasm -o mixed.wasm
  $ wax mixed.wasm -f wat
  (@feature "compact-import-section")
  (type (func))
  (type (func (param i32)))
  (import "env" (item "a" (func)) (item "b" (func (param i32))))
  (import "env" "c" (global i32))
  (import "env" "d" (global i64))
