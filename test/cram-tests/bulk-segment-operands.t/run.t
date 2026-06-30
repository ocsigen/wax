memory.init, table.init and call_indirect encode their two operands in a
different order in the binary format than in the text format, and the operands
live in different index spaces (data/memory, elem/table, type/table). Converting
to the binary format and back must keep each operand in its own space.

Here data segment 1, element segment 1 and type $t are selected (memory 0,
table 0 and table 0 are the implicit defaults):

  $ wax -i wat -f wasm bulk.wat -o bulk.wasm
  $ wax -i wasm -f wat bulk.wasm
  (type $t (func))
  (func $f)
  (func
    i32.const 0
    i32.const 0
    i32.const 0
    memory.init 1
    i32.const 0
    i32.const 0
    i32.const 0
    table.init 1
    i32.const 0
    call_indirect (type $t)
  )
  (table 2 funcref)
  (memory 1)
  (elem func )
  (elem func $f)
  (data "a")
  (data "bbbb")
