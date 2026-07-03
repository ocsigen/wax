An element segment in the funcidx (non-expression) encoding carries an elemkind
byte that the spec requires to be 0x00 (funcref). The binary reader used to read
this byte and discard it, so a corrupted non-zero elemkind was silently accepted
(and normalized to funcref on re-encoding) where the reference validator rejects
it. The reader now checks it. Regression: wasm-binary mutation fuzzer
(mutate-wasm) via the reference-differential.

  $ wax -i wasm -f wat bad.wasm
  File "bad.wasm", line 1, characters 23-23:
  Error: element kind must be 0x00, got 0x01
  [128]
