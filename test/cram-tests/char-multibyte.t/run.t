A character literal is a single Unicode code point, which may be a multi-byte
UTF-8 sequence written literally (an accent, a CJK ideograph, an emoji) — not
only the `\u{…}` escape form. Through WAT it stays an `(@char …)` annotation:

  $ wax lit.wax -f wat
  (func $ascii (result i32) (@char "A"))
  (func $accent (result i32) (@char "é"))
  (func $cjk (result i32) (@char "漢"))
  (func $emoji (result i32) (@char "😀"))

Each lowers to an `i32.const` of its code point (`é` = 233, `漢` = 28450,
`😀` = U+1F600 = 128512):

  $ wax lit.wax -f wasm -o lit.wasm && wax lit.wasm -f wat
  (type (func (result i32)))
  (func $ascii (result i32) i32.const 65)
  (func $accent (result i32) i32.const 233)
  (func $cjk (result i32) i32.const 28450)
  (func $emoji (result i32) i32.const 128512)
