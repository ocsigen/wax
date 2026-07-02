A function's locals have no per-group limit; the spec bounds only the total,
at 2^32-1 (as does the reference interpreter). A single local group larger
than 65535 is therefore accepted — here one group of 70000 i32 locals (count
LEB128 = f0 a2 04):

  $ printf '\000\141\163\155\001\000\000\000\001\004\001\140\000\000\003\002\001\000\012\010\001\006\001\360\242\004\177\013' > big.wasm
  $ wax -i wasm -f wasm big.wasm -o out.wasm

Declaring more than 2^32-1 locals in total is rejected, and the check happens
before the locals are materialised (here 0xffffffff + 1 in two groups):

  $ printf '\000\141\163\155\001\000\000\000\001\004\001\140\000\000\003\002\001\000\012\014\001\012\002\377\377\377\377\017\177\001\177\013' > toomany.wasm
  $ wax check -f wasm toomany.wasm
  File "toomany.wasm", line 1, characters 31-31:
  Error: too many locals
  [128]
