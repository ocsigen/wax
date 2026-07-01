The Wasm binary parser reports malformed input as diagnostics rather than
raising assertion failures or Failure exceptions.

Error messages follow the wording used by the WebAssembly specification's
test suite.

A file that does not start with the Wasm magic header:

  $ printf 'notwasm!' > bad-magic.wasm
  $ wax -i wasm bad-magic.wasm -f wat
  File "bad-magic.wasm", line 1, characters 0-0:
  Error: magic header not detected
  [128]

A correct magic but an unsupported binary version:

  $ printf '\000asm\002\000\000\000' > bad-version.wasm
  $ wax -i wasm bad-version.wasm -f wat
  File "bad-version.wasm", line 1, characters 4-4:
  Error: unknown binary version
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
  Error: unexpected end
  [128]

A section whose declared size exceeds the bytes actually present, even when the
content parsed so far is well-formed (here a type section declaring 5 bytes but
followed by only its 1-byte count of 0): the declared length is checked against
the end of the module, so this truncation is rejected rather than silently
parsed as an empty section.

  $ printf '\000asm\001\000\000\000\001\005\000' > short-section.wasm
  $ wax -i wasm short-section.wasm -f wat
  File "short-section.wasm", line 1, characters 10-10:
  Error: unexpected end
  [128]

A section whose body parses to fewer bytes than its declared size, leaving
trailing data inside the section (here a type section declaring 2 bytes but
whose count of 0 consumes only 1): the body must be exactly its declared length,
so the leftover byte is a size mismatch rather than being silently ignored.

  $ printf '\000asm\001\000\000\000\001\002\000\000' > trailing-section.wasm
  $ wax -i wasm trailing-section.wasm -f wat
  File "trailing-section.wasm", line 1, characters 11-11:
  Error: section size mismatch
  [128]

An LEB128 integer (here a section size) encoded with more bytes than its type
allows:

  $ printf '\000asm\001\000\000\000\001\200\200\200\200\200' > long-leb.wasm
  $ wax -i wasm long-leb.wasm -f wat
  File "long-leb.wasm", line 1, characters 14-14:
  Error: integer representation too long
  [128]
