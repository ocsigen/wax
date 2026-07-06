A NaN constant keeps its exact payload (and sign) through a binary round-trip:
the bits are carried as nan:0xPAYLOAD rather than collapsed to a plain "nan"
(which would canonicalise a signaling NaN to a quiet one).

  $ wax -i wat -f wasm nan.wat -o nan.wasm
  $ wax -i wasm -f wat nan.wasm
  (type (func (result f32)))
  (type (func (result f64)))
  (func (result f32)
    f32.const nan:0x200000
  )
  (func (result f64)
    f64.const nan:0x4000000000000
  )
  (func (result f32)
    f32.const -nan:0x200000
  )
  (export "f" (func 0))
  (export "g" (func 1))
  (export "h" (func 2))
