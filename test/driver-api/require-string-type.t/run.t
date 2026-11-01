With [require_string_type], a module whose string literals would silently build
byte arrays, because it designates no string type, is rejected.

A module designating its string type in some configurations is accepted in
those, and rejected in the others:

  $ ../assemble.exe --require-string-type -D js_strings=true untyped.wat
  ok
  $ ../assemble.exe --require-string-type -D js_strings=false untyped.wat
  Error:
    This string literal has no type, and the module does not designate a string
    type: it would build a byte array.
   ──➤  untyped.wat:7:4
  5 │    (@then
  6 │       (@string_type $string)))
  7 │    (@string $greeting "hello")
    ·    ^^^^^^^^^^^^^^^^^^^^^^^^^^^
  8 │    (func (export "message") (result (ref eq)) (@string "world")))
  9 │ 
  Hint:
    Designate the string type with (@string_type $t), or give the literal an
    explicit type.
  [128]

Without the option, the literals build byte arrays:

  $ ../assemble.exe -D js_strings=false untyped.wat
  ok

A string global is an untyped literal too:

  $ ../assemble.exe --require-string-type global.wat
  Error:
    This string literal has no type, and the module does not designate a string
    type: it would build a byte array.
   ──➤  global.wat:2:4
  1 │ (module
  2 │    (@string $greeting "hello")
    ·    ^^^^^^^^^^^^^^^^^^^^^^^^^^^
  3 │    (export "greeting" (global $greeting)))
  4 │ 
  Hint:
    Designate the string type with (@string_type $t), or give the literal an
    explicit type.
  [128]

Literals with an explicit type need no string type:

  $ ../assemble.exe --require-string-type typed.wat
  ok

The same, in Wax:

  $ ../assemble.exe --require-string-type -D js_strings=true untyped.wax
  ok
  $ ../assemble.exe --require-string-type -D js_strings=false untyped.wax
  Error:
    This string literal has no type, and the module does not designate a string
    type: it would build a byte array.
    ──➤  untyped.wax:9:5
   7 │ #[export]
   8 │ fn message() -> &eq {
   9 │     "world"
     ·     ^^^^^^^
  10 │ }
  11 │ 
  Hint:
    Designate the string type with #![string_type = t], or give the literal an
    explicit type.
  [128]
