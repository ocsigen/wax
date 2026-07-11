
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

- Exact function imports (custom-descriptors, `(func (exact …))`) are not fully
  matched: the export side is treated as inexact and `check_export_import_types`
  ignores the `exact` flag. So an exact import that should be rejected on a
  supertype export is accepted, and one satisfied only by an inexact export's
  *dynamic* type is rejected. Matching them properly means tracking per-export
  exactness (a directly-defined function is exact; a re-exported inexact import
  is not); the dynamic-type cases are, like all instantiation-time checks,
  beyond a static merge linker. See `exact-func-import.wast` in the linker
  suite's custom-descriptors golden.
