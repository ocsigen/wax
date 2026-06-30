An f32 constant is kept as its raw 32 bits, so a signaling NaN's payload
survives a binary round-trip exactly. (Decoding it to an OCaml float — a 64-bit
double — would quiet the NaN, since widening single to double sets the quiet
bit.) snan.wasm holds f32.const nan:0x200000; re-encoding it is byte-identical.

  $ wax -i wasm -f wasm snan.wasm -o out.wasm
  $ cmp snan.wasm out.wasm
