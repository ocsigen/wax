The name section may carry an EMPTY name — it is a custom section of arbitrary
byte strings — but no text identifier denotes one: `$` is not an identifier and
the quoted form `$""` is rejected outright ("an identifier cannot be the empty
string"). Emitting it produced WAT wax itself could not read back, so wax
accepted the binary and then rejected its own rendering of it (a mutate-wasm
FALSE_ACCEPT / VALIDATION_PARITY finding). An empty name is dropped at decode
instead, leaving the entity anonymous — which is what the name conveyed anyway.

The fixture is a module whose only content is a name section declaring an
empty module name:

  $ wax -i wasm -f wat empty-module-name.wasm
  
  $ wax -i wasm -f wat empty-module-name.wasm | grep -c '\$'
  0
  [1]

And the rendering is accepted on the way back in:

  $ wax -i wasm -f wat empty-module-name.wasm -o out.wat && wax check out.wat
