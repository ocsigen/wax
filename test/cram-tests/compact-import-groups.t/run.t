Compact import groups (compact-import-section proposal) are kept in the AST and
round-trip through both the text and binary forms, preserving Group1 (a type per
`(item …)`) and Group2 (name-only items sharing one final type).

  $ wax -i wat -f wat groups.wat
  (import "env" (item "a" (func (result i32))) (item "b" (global i32)))
  (import "env" (item "x") (item "y") (func (param i32)))

The encoder emits the compact section straight from the AST, so the grouping
survives a binary round-trip (no feature flag needed to preserve it):

  $ wax -i wat -f wasm groups.wat -o groups.wasm
  $ wax -i wasm -f wat groups.wasm
  (@feature "compact-import-section")
  (type (func (result i32)))
  (type (func (param i32)))
  (import "env" (item "a" (func (result i32))) (item "b" (global i32)))
  (import "env" (item "x") (item "y") (func (param i32)))
