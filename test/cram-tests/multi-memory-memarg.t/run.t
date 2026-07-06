With multi-memory, a load/store memarg encodes an explicit memory index between
the alignment and the offset (signalled by bit 6 of the alignment). The memory
index and the offset must not be confused: here the load targets memory $m1 with
offset 8, and a round-trip through the binary format must preserve both.

  $ wax -i wat -f wasm load.wat -o load.wasm
  $ wax -i wasm -f wat load.wasm
  (type (func (param i32) (result i32)))
  (func (param i32) (result i32)
    local.get 0
    i32.load $m1 offset=8
  )
  (memory $m0 1)
  (memory $m1 1)
