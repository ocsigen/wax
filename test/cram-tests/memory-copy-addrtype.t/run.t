memory.copy between memories of different address types checks each address
operand against its own memory: the destination address has the destination
memory's address type, the source address the source memory's, and the length
the smaller of the two. Here the destination is i64 and the source is i32, so a
valid copy supplies an i64 destination address and an i32 source address.

  $ wax check -f wat valid.wat
  $ echo $?
  0

Supplying the source address as i64 (the destination's type) is rejected — the
source operand is checked against the source memory.

  $ wax check -f wat bad.wat
  Error: Type mismatch: this instruction expects type i32
    but the stack has type i64
   ──➤  bad.wat:4:47
  2 │   (memory $dst i64 1)
  3 │   (memory $src i32 1)
  4 │   (func (memory.copy $dst $src (i64.const 0) (i64.const 0) (i32.const 0))))
    ·                                               ^^^^^^^^^^^
  5 │ 
  [123]
