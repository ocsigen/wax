Converting Wat to the binary format must report an unresolved named reference as
a located diagnostic, not crash with an uncaught exception. A text input is
validated before it is converted, so validation reports the unresolved reference
(the binary lowering keeps its own backstop for the same class).

A branch to a label that is not in scope:

  $ wax -i wat -f wasm badlabel.wat -o /dev/null
  Error: Unknown label: '$nope' is not bound.
   ──➤  badlabel.wat:1:19
  1 │ (module (func (br $nope)))
    ·                   ^^^^^
  2 │ 
  [128]

A call to a function identifier that is not defined:

  $ wax -i wat -f wasm badcall.wat -o /dev/null
  Error: Unknown function: index '$nope' is not bound.
   ──➤  badcall.wat:1:21
  1 │ (module (func (call $nope)))
    ·                     ^^^^^
  2 │ 
  [128]
