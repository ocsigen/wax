The Wasm binary parser reports malformed input as diagnostics rather than
raising assertion failures or Failure exceptions.

A file that does not start with the Wasm magic header:

  $ printf 'notwasm!' > bad-magic.wasm
  $ wax -i wasm bad-magic.wasm -f wat
  File "bad-magic.wasm", line 1, characters 0-0:
  Error: not a WebAssembly binary file (invalid magic header)
  [128]

A valid header followed by an unknown section id:

  $ printf '\000asm\001\000\000\000\016\000' > bad-section.wasm
  $ wax -i wasm bad-section.wasm -f wat
  File "bad-section.wasm", line 1, characters 10-10:
  Error: malformed section id 14
  [128]

A section whose declared contents run past the end of the input:

  $ printf '\000asm\001\000\000\000\001\012' > truncated.wasm
  $ wax -i wasm truncated.wasm -f wat
  File "truncated.wasm", line 1, characters 10-10:
  Error: unexpected end of input
  [128]
