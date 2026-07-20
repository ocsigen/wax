An invalid binary can declare a function whose type index is out of range (here
type 0, with no type section). The binary reader must not crash on it: it keeps
the index unexpanded when disassembling, and validation reports the unknown type
rather than raising an uncaught exception.

  $ wax -i wasm -f wat bad.wasm
  (func (type 0))

  $ wax check bad.wasm
  Error: Unknown type: index '0' is not bound.
  [128]

A value-type discriminator is a single byte, not an unbounded LEB. An overlong
encoding such as `ff 00` (whose 7-bit value `0x7f` is `i32`) must be rejected,
not silently read as `i32` — otherwise `overlong-valtype.wasm` (a param typed
`ff 00`) is wrongly accepted while both the reference interpreter and
`wasm-tools` reject it. Regression: found by the WASM-mutation fuzzer.

  $ wax -i wasm -f wat overlong-valtype.wasm
  File "overlong-valtype.wasm", line 1, characters 17-17:
  Error: malformed reference type 0xff
  [128]
