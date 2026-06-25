Character and string literals.

A character literal is an `i32` code point (including `\u{…}` escapes); a string
literal builds a byte array via `array.new_fixed`, with its type taken from a
`T #` prefix or the context, defaulting to `[mut i8]`.

  $ wax lit.wax -f wat -v
  (type $chars (array i8))
  
  (func $newline (export "newline") (result i32) (@char "\n" ))
  
  (func $byte_escape (export "byte_escape") (result i32) (@char "A" ))
  
  (func $code_point (export "code_point") (result i32) (@char "😀" ))
  
  (func $default_string (export "default_string") (result (ref eq))
    (@string "hi" )
  )
  
  (func $named_string (export "named_string") (result (ref $chars))
    (@string $chars "hi!" )
  )
  
  (func $from_context (export "from_context") (result (ref $chars))
    (local $s (ref $chars))
    (local.set $s (@string $chars "yo" ))
    (local.get $s)
  )
  
  (func $binary_blob (export "binary_blob") (result (ref $chars))
    (@string $chars "a\01b" )
  )

Through WAT the literals are kept as `(@char …)` / `(@string …)` annotations, so
they round-trip back to Wax unchanged — characters included.

  $ wax lit.wax -f wat -o lit.wat && wax lit.wat -f wax
  type chars = [i8];
  
  #[export = "newline"]
  fn newline() -> i32 {
      '\n';
  }
  
  #[export = "byte_escape"]
  fn byte_escape() -> i32 {
      'A';
  }
  
  #[export = "code_point"]
  fn code_point() -> i32 {
      '😀';
  }
  
  #[export = "default_string"]
  fn default_string() -> &eq {
      "hi";
  }
  
  #[export = "named_string"]
  fn named_string() -> &chars {
      chars#"hi!";
  }
  
  #[export = "from_context"]
  fn from_context() -> &chars {
      let s: &chars = "yo";
      s;
  }
  
  #[export = "binary_blob"]
  fn binary_blob() -> &chars {
      chars#"a\01b";
  }

Through WASM the round-trip is best-effort. Character literals lowered to a
plain `i32.const`, so they come back as the integer code points. A string is
recovered from its `array.new_fixed` only when its bytes are a reasonable UTF-8
string; `binary_blob` (which holds a control byte) stays an array literal.

  $ wax lit.wax -f wasm -o lit.wasm && wax lit.wasm -f wax
  type chars = [i8];
  type t = fn() -> i32;
  type t_2 = fn() -> &eq;
  type t_3 = fn() -> &chars;
  type t_4 = [mut i8];
  #[export = "newline"]
  fn newline() -> i32 {
      10;
  }
  #[export = "byte_escape"]
  fn byte_escape() -> i32 {
      65;
  }
  #[export = "code_point"]
  fn code_point() -> i32 {
      128512;
  }
  #[export = "default_string"]
  fn default_string() -> &eq {
      "hi";
  }
  #[export = "named_string"]
  fn named_string() -> &chars {
      chars#"hi!";
  }
  #[export = "from_context"]
  fn from_context() -> &chars {
      let s: &chars = "yo";
      s;
  }
  #[export = "binary_blob"]
  fn binary_blob() -> &chars {
      [97, 1, 98];
  }
