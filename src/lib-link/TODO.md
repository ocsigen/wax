
- Support Wat/Wax input and output
- Tests
- Preserve types (dedup up to syntactic equality)

## Known limitations

- A table initializer expression may only read an *imported* global (a defined
  global follows the table section and cannot be forward-referenced). So when a
  table initializer reads an imported global that linking *resolves*
  (internalises it into a defined global), the merged module would be invalid.
  The linker rejects this with an error rather than emitting an invalid module.
  For comparison, binaryen's `wasm-merge` either rejects the input outright
  (v120) or silently drops the initializer, changing the table's semantics
  (v129). Supporting it would require inlining the (constant) global initializer
  into the table initializer in place of the `global.get`.

- Exact function imports (custom-descriptors, `(func (exact …))`) are matched by
  requiring the export's function type to equal the imported type exactly. This
  is correct when the export's static type is its real type (a directly-defined
  function, or an exact re-export). It cannot accept the case where an exact
  import is satisfied only by an *inexact* re-export whose declared type is a
  supertype but whose runtime type is the imported type — that is an
  instantiation-time (dynamic) check, beyond a static merge linker, so the
  linker rejects it. See `exact-func-import.wast` in the linker suite's
  custom-descriptors golden (the one remaining rejection).
