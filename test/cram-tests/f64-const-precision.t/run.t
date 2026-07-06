A float constant is rendered as a hex float when disassembled, so its value
round-trips exactly. (string_of_float would print "%.12g" — only 12 significant
digits — losing precision, since a double needs 17.) pi.wasm holds the f64
constant for pi; disassembly must show the exact value, not a truncated decimal.

  $ wax -i wasm -f wat pi.wasm
  (type (func (result f64)))
  (func (result f64)
    f64.const 0x1.921fb54442d18p+1
  )
  (export "f" (func 0))
