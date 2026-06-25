A `(@string ...)` global occupies a global index, so an inline export on a
later global must account for it. Here three `(@string)` globals precede the
exported `$null` global (whose name also names a type), so a regression in the
binary export-index counter would point the export at the wrong global.

  $ wax m.wat -f wasm -o m.wasm && wax m.wasm -f wat | grep 'export "null"'
  (export "null" (global $null))
