A string literal builds an `i8` or `i16` array. An `i8` array holds the raw
bytes (the UTF-8 encoding); an `i16` array holds the UTF-16 code units, so it
must be a valid Unicode string. Through WAT the literal stays an `(@string …)`
annotation:

  $ wax utf16.wax -f wat
  (type $utf16 (array (mut i16)))
  (type $utf8 (array (mut i8)))
  
  (func $wide (export "wide") (result (ref $utf16)) (@string $utf16 "hé😀"))
  
  (func $narrow (export "narrow") (result (ref $utf8)) (@string "hé"))



Lowered to binary, the annotation expands to `array.new_fixed` over the encoded
elements: UTF-16 code units for the `i16` array (`😀` becomes the surrogate pair
`55357 56832`), raw UTF-8 bytes for the `i8` array:

  $ wax utf16.wax -f wasm -o utf16.wasm && wax utf16.wasm -f wat
  (type $utf16 (array (mut i16)))
  (type $utf8 (array (mut i8)))
  (type (func (result (ref $utf16))))
  (type (func (result (ref $utf8))))
  (func $wide (result (ref $utf16))
    i32.const 104
    i32.const 233
    i32.const 55357
    i32.const 56832
    array.new_fixed $utf16 4
  )
  (func $narrow (result (ref $utf8))
    i32.const 104
    i32.const 195
    i32.const 169
    array.new_fixed $utf8 3
  )
  (export "wide" (func $wide))
  (export "narrow" (func $narrow))

The element type also drives decompilation, so the arrays come back as strings:

  $ wax utf16.wasm -f wax
  type utf16 = [mut i16];
  type utf8 = [mut i8];
  type t = fn() -> &utf16;
  type t_2 = fn() -> &utf8;
  #[export = "wide"]
  fn wide() -> &utf16 {
      "hé😀";
  }
  #[export = "narrow"]
  fn narrow() -> &utf8 {
      "hé";
  }

Only `i8` and `i16` arrays are allowed, and an `i16` string must be valid
Unicode:

  $ wax bad-type.wax -f wat
  Error: A string literal can only build an [i8] or [i16] array.
   ──➤  bad-type.wax:2:16
  1 │ type w = [mut i32];
  2 │ fn f() -> &w { w # "hi"; }
    ·                ^^^^^^^^
  3 │ 
  [128]

  $ wax bad-unicode.wax -f wat
  Error: A string building an [i16] array must be a valid Unicode string.
   ──➤  bad-unicode.wax:2:16
  1 │ type w = [mut i16];
  2 │ fn f() -> &w { w # "\ff"; }
    ·                ^^^^^^^^^
  3 │ 
  [128]

A module-level `(@string …)` global honours its array type the same way: with a
named `i16` type it is UTF-16-encoded, otherwise it defaults to `i8`:

  $ wax global.wat -f wasm -o global.wasm && wax global.wasm -f wat
  (type $w (array (mut i16)))
  (type (func (result (ref $w))))
  (type (array (mut i8)))
  (func (result (ref $w)) global.get $wide)
  (global $wide (ref $w)
    i32.const 104
    i32.const 233
    i32.const 55357
    i32.const 56832
    array.new_fixed $w 4
  )
  (global $narrow (ref 2) i32.const 104
                          i32.const 105
                          array.new_fixed 2 2)
  (export "g" (func 0))
