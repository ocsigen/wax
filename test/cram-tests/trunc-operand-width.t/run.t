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

The mirror image is the int->float CONVERSION, whose source width the opcode
names (`f32.convert_i32_u` takes an `i32`). That source is normally left
unpinned when it is an `i32`, since `i32` is what a flexible numeric re-parses
to anyway — but an operand that re-parses ADAPTIVELY (a hole, or an untyped
`select` of them) does not default: under the conversion's own `as f32_u` it
takes the TARGET type, and the conversion collapses to nothing. So the i32 pin is
load-bearing exactly there, and only there:

  $ cat > conv.wat <<'WAT'
  > (module
  >   (func (export "adaptive") (result i32)
  >     unreachable i32.const 0 select f32.convert_i32_u i32.trunc_f32_u)
  >   (func (export "hole") (result i32)
  >     unreachable f32.convert_i32_u i32.trunc_f32_u)
  >   (func (export "concrete") (param $x i32) (result i32)
  >     local.get $x f32.convert_i32_u i32.trunc_f32_u))
  > WAT
  $ wax -i wat -f wax --faithful conv.wat | grep -oE '\(0\?_:_\) as i32|_ as i32 as f32_u|x as f32_u'
  (0?_:_) as i32
  _ as i32 as f32_u
  x as f32_u

A concrete operand fixes its own width and gets no pin (the last line above), and
all three conversions survive the round trip. Without the pin the two adaptive
ones lost theirs — a wasm-smith finding, reported by both the width-histogram and
the `--faithful` opcode-stream oracles.

  $ wax -i wat -f wax --faithful conv.wat -o conv.wax && wax -i wax -f wasm conv.wax -o conv.wasm
  $ wax -i wasm -f wat conv.wasm | grep -c 'f32.convert_i32_u'
  3
