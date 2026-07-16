The compact-import-section proposal writes a run of consecutive imports that
share a module name once, under that module name, in the binary import section.
It is off by default and enabled for output with `-X compact-import-section`; the
decoder always accepts the compact form. The grouping is kept in the AST, so a
compact binary round-trips back to the same compact form rather than being
flattened.

  $ wax imports.wat -f wasm -o plain.wasm
  $ wax -X compact-import-section imports.wat -f wasm -o compact.wasm

The compact section is smaller — the three consecutive `env` imports share one
module name rather than repeating it:

  $ test $(wc -c < compact.wasm) -lt $(wc -c < plain.wasm) && echo smaller
  smaller

It decodes back to the same imports, in order, preserving the compact grouping:
the three consecutive `env` imports print as one grouped `(import "env" (item …)
…)`, while `other` and the later, non-adjacent `env "d"` stay separate.

  $ wax compact.wasm -f wat
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
