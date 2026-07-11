
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

- Exact function imports (custom-descriptors, `(func (exact …))`) are matched
  soundly but conservatively: the export must itself be exact (a directly-defined
  function, or an exact import) and have exactly the imported type. An exact
  import satisfied only by an *inexactly*-imported function that is re-exported
  is rejected, even though the WebAssembly spec accepts it — the spec checks the
  function's *dynamic* type at instantiation, which a static merge linker cannot
  do, so it fails rather than accept an unverifiable (and possibly unsound)
  match. See `exact-func-import.wast` in the linker suite's custom-descriptors
  golden.
