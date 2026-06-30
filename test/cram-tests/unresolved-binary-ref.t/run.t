Lowering Wasm text to the binary format must report an unresolved named
reference as a located diagnostic, not crash with an uncaught exception.

A branch to a label that is not in scope:

  $ wax -i wat -f wasm badlabel.wat -o /dev/null
  Error: Unknown label $nope.
   ──➤  badlabel.wat:1:19
  1 │ (module (func (br $nope)))
    ·                   ^^^^^
  2 │ 
  [128]

A call to a function identifier that is not defined:

  $ wax -i wat -f wasm badcall.wat -o /dev/null
  Error: Unknown identifier $nope.
   ──➤  badcall.wat:1:21
  1 │ (module (func (call $nope)))
    ·                     ^^^^^
  2 │ 
  [128]
