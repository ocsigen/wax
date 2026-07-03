A float->int truncation types its operand by the *float* being truncated, not by
the integer result width. For a non-inlinable operand (here a polymorphic stack
after `unreachable`) the decompiler materialises the operand as a hole cast, and
that cast must use the operand's float width: `i32.trunc_f64_s` -> `_ as f64`,
`i64.trunc_f32_s` -> `_ as f32`. (It used `floattype sz` — the integer result
width — so `i32.trunc_f64_s` produced `_ as f32`, round-tripping to the wrong
`i32.trunc_f32_s`.)

  $ printf '(module (func (result i32) unreachable i32.trunc_f64_s))\n' > a.wat
  $ wax -i wat -f wax a.wat | grep -o '_ as f[0-9]*'
  _ as f64

  $ printf '(module (func (result i64) unreachable i64.trunc_f32_s))\n' > b.wat
  $ wax -i wat -f wax b.wat | grep -o '_ as f[0-9]*'
  _ as f32

The round-trip therefore preserves the instruction width:

  $ wax -i wat -f wax a.wat -o a.wax && wax -i wax -f wasm a.wax -o a.wasm
  $ wax -i wasm -f wat a.wasm | grep -o 'i32.trunc_f[0-9]*_s'
  i32.trunc_f64_s
