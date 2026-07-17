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

Memories (and tables) imported via a compact group are counted like individual
imports, so in a module with conditionals a numeric memory reference is rejected
with the same clean diagnostic (before, the group was uncounted, the guard
stayed off, and the numeric reference slipped through):

  $ cat > cond-mem.wat <<'WAT'
  > (module
  >   (import "env" (item "a" (memory $a 1)) (item "b" (memory $b 1)))
  >   (@if $D (@then (func $cond)))
  >   (func (drop (memory.size))))
  > WAT

  $ wax -i wat -f wax cond-mem.wat
  Error:
    Numeric references to module fields are not supported in a module with
    conditional annotations; use a symbolic $name.
   ──➤  cond-mem.wat:4:27
  2 │   (import "env" (item "a" (memory $a 1)) (item "b" (memory $b 1)))
  3 │   (@if $D (@then (func $cond)))
  4 │   (func (drop (memory.size))))
    ·                           ^
  5 │ 
  [128]
