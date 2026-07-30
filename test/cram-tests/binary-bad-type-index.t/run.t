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

Every other single-byte discriminator is read the same way. Each binary below
spells one of them overlong, so that its 7-bit value is a byte the decoder
accepts, and each must be rejected (`wasm-tools` rejects all four):

An import kind — `ff 00` is `0x7f`, the compact-import-section group marker, so
this once decoded as a group with no items:

  $ wax check overlong-import-kind.wasm
  File "overlong-import-kind.wasm", line 1, characters 16-16:
  Error: malformed import kind 0xff
  [128]

An export description — `80 00` is `0x00`, a function export:

  $ wax check overlong-export-desc.wasm
  File "overlong-export-desc.wasm", line 1, characters 24-24:
  Error: unknown export description 0x80
  [128]

A tag attribute, which the spec fixes at the single byte `0x00`:

  $ wax check overlong-tag-attr.wasm
  File "overlong-tag-attr.wasm", line 1, characters 23-23:
  Error: malformed tag attribute
  [128]

A struct field's storage type, which shares the value-type encoding, so `ff 00`
once read as `i32`:

  $ wax check overlong-storagetype.wasm
  File "overlong-storagetype.wasm", line 1, characters 14-14:
  Error: malformed reference type 0xff
  [128]

A branching cast's flags byte is a *constrained* byte rather than a set of
independent bits: the spec's `castflags` production admits only `0`..`3` (bit 0 is
the source type's nullability, bit 1 the target's), so every other bit is
reserved and a nonzero one is malformed. Masking the two bits out and ignoring the
rest — what the decoder used to do — silently accepts a byte the encoding does not
define, here `07` on a `br_on_cast` whose written flags were `03`; the reference
interpreter ("malformed br_on_cast flags") and `wasm-tools` ("invalid cast flags:
00000111") both reject it. The same check guards `br_on_cast_fail` and the
custom-descriptors pair `br_on_cast_desc_eq`/`_fail`, which share the production.
Regression: found by the WASM-mutation fuzzer.

  $ wax check br-on-cast-flags.wasm
  File "br-on-cast-flags.wasm", line 1, characters 35-35:
  Error: malformed br_on_cast flags
  [128]
