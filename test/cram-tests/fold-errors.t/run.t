Folding runs before validation on a same-format wat->wat conversion (which is
not validated) and on a trusted wasm->wat binary, so it must report a malformed
module as a diagnostic rather than crash with an uncaught exception.

An undefined index (here a call to an unknown function):

  $ wax --fold bad_call.wat -o out.wat
  Error: This index is unbound.
   ──➤  bad_call.wat:1:24
  1 │ (module (func $f (call $undef)))
                             ^^^^^^
  [128]

An index that resolves to the wrong kind of type (a func typeuse naming a
struct type):

  $ wax --fold bad_type.wat -o out.wat
  Error: This type should be a function type.
   ──➤  bad_type.wat:1:43
  1 │ (module (type $s (struct)) (func $f (type $s)))
                                                ^^
  [128]

An unbound branch label:

  $ wax --fold bad_label.wat -o out.wat
  Error: This label is unbound.
   ──➤  bad_label.wat:1:22
  1 │ (module (func $f (br $undef)))
                           ^^^^^^
  [128]
