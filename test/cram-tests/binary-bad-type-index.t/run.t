An invalid binary can declare a function whose type index is out of range (here
type 0, with no type section). The binary reader must not crash on it: it keeps
the index unexpanded when disassembling, and validation reports the unknown type
rather than raising an uncaught exception.

  $ wax -i wasm -f wat bad.wasm
  (func (type 0))

  $ wax check bad.wasm
  Error: Unknown type: index 0 is not bound.
  Error: Unknown type: index 0 is not bound.
  Error: Unknown type: index 0 is not bound.
  [123]
