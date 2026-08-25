The compact-import-section shared-type text form is strictly name-only: a
shared-type item may not bind an identifier, so imports that must be referenced
by name are written with a type per item instead.

  $ wax -i wat -f wat g2.wat
  Error:
    An import item under a shared type may not bind an identifier; give each
    item its own type instead.
   ──➤  g2.wat:2:3
  1 │ (module
  2 │   (import "env"
    · ╭─^
  3 │     (item $a "a")
    · │
  4 │     (item $b "b")
    · │
  5 │     (global i32))
    · ╰───────────────^
  6 │   (func (result i32) global.get $a global.get $b i32.add))
  7 │ 
  [128]

The per-item form binds each id in its own type. When every item's type agrees,
the binary encoder still uses the shared-type encoding (0x7E) — the ids ride the
name section — so nothing is lost by spelling the types out:

  $ wax -i wat -f wat g1.wat
  (import "env" (item "a" (global $a i32)) (item "b" (global $b i32)))
  (func (result i32)
    global.get $a
    global.get $b
    i32.add
  )
  $ wax -i wat -f wasm g1.wat -o g1.wasm

The import section holds one shared-type entry: "env", the empty name, the 0x7E
marker, the shared globaltype, then the two field names:

  $ xxd -s 17 -l 17 g1.wasm
  00000011: 0103 656e 7600 7e03 7f00 0201 6101 6203  ..env.~.....a.b.
  00000021: 02                                       .

Decompiling restores the ids from the name section, back to the per-item form:

  $ wax -i wasm -f wat g1.wasm
  (@feature "compact-import-section")
  (type (func (result i32)))
  (import "env" (item "a" (global $a i32)) (item "b" (global $b i32)))
  (func (result i32)
    global.get $a
    global.get $b
    i32.add
  )

A shared-type group whose items go unnamed stays in the name-only form through
both text and binary round-trips:

  $ cat > anon.wat <<'EOF'
  > (module
  >   (import "env" (item "a") (item "b") (global i32)))
  > EOF
  $ wax -i wat -f wat anon.wat
  (import "env" (item "a") (item "b") (global i32))
  $ wax -i wat -f wasm anon.wat -o anon.wasm
  $ wax -i wasm -f wat anon.wasm
  (@feature "compact-import-section")
  (import "env" (item "a") (item "b") (global i32))
