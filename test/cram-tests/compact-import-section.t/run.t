The compact-import-section proposal writes a run of consecutive imports that
share a module name once, under that module name, in the binary import section.
It is off by default and enabled with `-X compact-import-section`; the decoder
always accepts the compact form.

The text formats (wax/wat) carry an authorial import layout, so the encoder
preserves what is written and never coalesces on their behalf: separate
`(import …)` statements stay separate even with the feature on. So a wat input
compiled with `-X` is byte-identical to one compiled without it (the imports are
not grouped either way):

  $ wax imports.wat -f wasm -o plain.wasm
  $ wax -X compact-import-section imports.wat -f wasm -o textout.wasm
  $ cmp plain.wasm textout.wasm && echo identical
  identical

Decoding confirms the imports stay individual, in order:

  $ wax textout.wasm -f wat
  (type (func))
  (type (func (param i32)))
  (import "env" "a" (func))
  (import "env" "b" (func (param i32)))
  (import "env" "c" (global i32))
  (import "other" "x" (func))
  (import "env" "d" (memory 1))

A wax `import "m" { … }` block or a wat `(import "m" (item …) …)` group is an
explicit compact entry: those are lowered to the compact form (see the
compact-import-groups test). To compress an *already-compiled* binary — which
has no authorial text structure to respect — feed it back with the feature on.
This is the one path that coalesces runs of same-module imports:

  $ wax plain.wasm -X compact-import-section -f wasm -o compressed.wasm

The compact section is smaller — the three consecutive `env` imports share one
module name rather than repeating it:

  $ test $(wc -c < compressed.wasm) -lt $(wc -c < plain.wasm) && echo smaller
  smaller

It decodes back to the same imports, in order, preserving the compact grouping:
the three consecutive `env` imports print as one grouped `(import "env" (item …)
…)`, while `other` and the later, non-adjacent `env "d"` stay separate.

  $ wax compressed.wasm -f wat
  (@feature "compact-import-section")
  (type (func))
  (type (func (param i32)))
  (import "env"
    (item "a" (func))
    (item "b" (func (param i32)))
    (item "c" (global i32))
  )
  (import "other" "x" (func))
  (import "env" "d" (memory 1))
