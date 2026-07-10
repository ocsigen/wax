A wax extension over the compact-import-section text form: a shared-type
(Group2) item may bind an identifier, `(item $id "name")`, which the standard
form (`(item "name")`) cannot express — so the imports can be referenced by
name. The id is text-only; the binary import section stays standard (name-only
items) and the id round-trips through the binary name section, so wasm-tools
still reads the binary.

  $ wax -i wat -f wat g2.wat
  (import "env" (item $a "a") (item $b "b") (global i32))
  (func (result i32)
    global.get $a
    global.get $b
    i32.add
  )

The ids survive a binary round-trip (via the name section):

  $ wax -i wat -f wasm g2.wat -o g2.wasm
  $ wax -i wasm -f wat g2.wasm
  (type (func (result i32)))
  (import "env" (item $a "a") (item $b "b") (global i32))
  (func (result i32)
    global.get $a
    global.get $b
    i32.add
  )
