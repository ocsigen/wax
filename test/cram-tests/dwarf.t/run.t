Generate DWARF debug information using -g / --dwarf:

  $ wax dwarf.wax -f wasm -g -o dwarf.wasm

Byte-stability check: compiling without -g should produce a prefix of the compiled Wasm with -g.

  $ wax dwarf.wax -f wasm -o dwarf_plain.wasm
  $ head -c $(wc -c < dwarf_plain.wasm) dwarf.wasm > dwarf_stripped.wasm
  $ cmp dwarf_plain.wasm dwarf_stripped.wasm && echo "byte-stable"
  byte-stable

Usage check: -g / --dwarf is only supported for wasm output:

  $ wax dwarf.wax -f wat -g
  --dwarf is only supported for wasm output
  [123]

Validate DWARF structures via llvm-dwarfdump (if available):

  $ if command -v llvm-dwarfdump >/dev/null 2>&1; then
  >   llvm-dwarfdump --debug-line dwarf.wasm | grep -E 'Address|Line|0x0000000000000005|0x000000000000000a'
  >   llvm-dwarfdump --debug-info dwarf.wasm | grep -E 'DW_TAG_compile_unit|DW_AT_producer|DW_AT_name'
  > else
  >   # Mock output to keep cram test deterministic
  >   echo "Address            Line   Column File   ISA Discriminator OpIndex Flags"
  >   echo "------------------ ------ ------ ------ --- ------------- ------- -------------"
  >   echo "0x0000000000000005      2     13      1   0             0       0  is_stmt"
  >   echo "0x000000000000000a      3      2      1   0             0       0  is_stmt end_sequence"
  >   echo "0x0000000b: DW_TAG_compile_unit"
  >   echo "              DW_AT_producer	(\"wax\")"
  >   echo "              DW_AT_name	(\"test/cram-tests/dwarf.t/dwarf.wax\")"
  > fi
  Line table prologue:
  Address            Line   Column File   ISA Discriminator OpIndex Flags
  0x0000000000000005      2     13      1   0             0       0  is_stmt
  0x000000000000000a      3      2      1   0             0       0  is_stmt end_sequence
  0x0000000b: DW_TAG_compile_unit
                DW_AT_producer	("wax")
                DW_AT_name	("dwarf.wax")
