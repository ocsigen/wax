A string literal can build a JavaScript string: a plain one, of type
`(ref extern)`, or one wrapped in a struct whose single field is an `anyref` or
an `externref`. It is lowered to an imported string constant (the JS String
Builtins' `importedStringConstants`), from the import module the module
declares with `#![string_imports = "…"]`. `#![string_type = t]` gives the type
a bare literal builds; under a conditional, it can differ between
configurations. Through WAT, both are annotations and the literals stay
`(@string …)`:

  $ wax strings.wax -f wat
  ;; The runtime representation of a string depends on the configuration: a
  ;; byte array, or a JavaScript string wrapped in a struct.
  (type $bytes (array (mut i8)))
  (type $js (struct (field $s externref)))
  (@string_imports "str")
  (@if $js_strings (@then (@string_type $js)))
  (@string $greeting "hello")
  (func $message (export "message") (result (ref eq)) (@string "world"))
  ;; A plain JavaScript string, whatever the configuration.
  (func $plain (export "plain") (result (ref extern)) (@string extern "plain"))
  ;; A byte array, whatever the configuration.
  (func $raw (export "raw") (result (ref $bytes)) (@string $bytes "raw"))

and back to Wax:

  $ wax strings.wax -f wat -o strings.wat && wax strings.wat -f wax
  // The runtime representation of a string depends on the configuration: a
  // byte array, or a JavaScript string wrapped in a struct.
  type bytes = [mut i8];
  type js = { s: &?extern };
  #![string_imports = "str"]
  #[if(js_strings)]
  {
      #![string_type = js]
  }
  const greeting = "hello";
  #[export]
  fn message() -> &eq {
      "world";
  }
  // A plain JavaScript string, whatever the configuration.
  #[export]
  fn plain() -> &extern {
      extern#"plain";
  }
  // A byte array, whatever the configuration.
  #[export]
  fn raw() -> &bytes {
      bytes#"raw";
  }

Desugared, a JavaScript string becomes a `global.get` of an imported string
constant, one per distinct text, wrapped in a `struct.new` for a struct type:

  $ wax strings.wax -D js_strings=true -f wat --desugar
  (import "str" "hello" (global $<js-string>0 (ref extern)))
  (import "str" "world" (global $<js-string>1 (ref extern)))
  (import "str" "plain" (global $<js-string>2 (ref extern)))
  ;; The runtime representation of a string depends on the configuration: a
  ;; byte array, or a JavaScript string wrapped in a struct.
  (type $bytes (array (mut i8)))
  (type $js (struct (field $s externref)))
  (global $greeting (ref $js) (struct.new $js (global.get $<js-string>0)))
  (func $message (export "message") (result (ref eq))
    (struct.new $js (global.get $<js-string>1))
  )
  ;; A plain JavaScript string, whatever the configuration.
  (func $plain (export "plain") (result (ref extern))
    (global.get $<js-string>2)
  )
  ;; A byte array, whatever the configuration.
  (func $raw (export "raw") (result (ref $bytes))
    (array.new_fixed $bytes 3 (i32.const 114) (i32.const 97) (i32.const 119))
  )

  $ wax strings.wax -D js_strings=false -f wat --desugar
  (import "str" "plain" (global $<js-string>0 (ref extern)))
  ;; The runtime representation of a string depends on the configuration: a
  ;; byte array, or a JavaScript string wrapped in a struct.
  (type $bytes (array (mut i8)))
  (type $js (struct (field $s externref)))
  (global $greeting (ref $bytes)
    (array.new_fixed $bytes 5 (i32.const 104) (i32.const 101) (i32.const 108)
      (i32.const 108) (i32.const 111))
  )
  (func $message (export "message") (result (ref eq))
    (array.new_fixed $bytes 5 (i32.const 119) (i32.const 111) (i32.const 114)
      (i32.const 108) (i32.const 100))
  )
  ;; A plain JavaScript string, whatever the configuration.
  (func $plain (export "plain") (result (ref extern))
    (global.get $<js-string>0)
  )
  ;; A byte array, whatever the configuration.
  (func $raw (export "raw") (result (ref $bytes))
    (array.new_fixed $bytes 3 (i32.const 114) (i32.const 97) (i32.const 119))
  )

The imported string constants come after the module's own imports, and numeric
references to the module's globals are shifted past them. An `anyref` field
takes the internalized string:

  $ wax numeric.wat -f wat --desugar
  (import "env" "g" (global i32))
  (import "str" "hello" (global $<js-string>0 (ref extern)))
  (type $js (struct (field anyref)))
  (global i32 (i32.const 7))
  (func (export "f") (result i32 (ref eq))
    (global.get 2)
    (struct.new $js (any.convert_extern (global.get $<js-string>0)))
  )

A JavaScript string needs the import module of the string constants:

  $ wax missing-imports.wax -f wat
  Error:
    This string builds a JavaScript string, but the module does not declare the
    import module of its string constants.
   ──➤  missing-imports.wax:3:5
  1 │ #[export]
  2 │ fn f() -> &extern {
  3 │     extern#"no import module";
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │ }
  5 │ 
  Hint:
    Declare the import module of the string constants with
    '#![string_imports = "…"]'.
  [128]

  $ wax missing-imports.wat -v -f wasm -o /dev/null
  Error:
    This string builds a JavaScript string, but the module does not declare the
    import module of its string constants.
   ──➤  missing-imports.wat:2:44
  1 │ (module
  2 │   (func (export "f") (result (ref extern)) (@string extern "x")))
    ·                                            ^^^^^^^^^^^^^^^^^^^^
  3 │ 
  Hint:
    Declare the import module of the string constants with
    '(@string_imports "…")'.
  [128]

  $ wax missing-imports.wat -f wat --desugar
  Error:
    This string builds a JavaScript string, but the module does not declare the
    import module of its string constants.
   ──➤  missing-imports.wat:2:44
  1 │ (module
  2 │   (func (export "f") (result (ref extern)) (@string extern "x")))
    ·                                            ^^^^^^^^^^^^^^^^^^^^
  3 │ 
  Hint: Declare it with a (@string_imports "…") annotation.
  [128]

The string type must be one a literal can build:

  $ wax bad-type.wax -f wat
  Error:
    Type 'pair' cannot be the string type: it should be an [i8] or [i16] array,
    a struct whose single field is an [anyref] or an [externref], or [extern].
   ──➤  bad-type.wax:3:18
  1 │ type pair = { a: i32, b: i32 };
  2 │ #![string_imports = "str"]
  3 │ #![string_type = pair]
    ·                  ^^^^
  4 │ 
  [128]

Each setting is declared at most once per configuration:

  $ wax twice.wat -v -f wasm -o /dev/null
  Error: The module already declares its string type.
   ──➤  twice.wat:5:3
  2 │   (type $js (struct (field externref)))
  3 │   (@string_imports "str")
  4 │   (@string_type $js)
    ·   ^^^^^^^^^^^^^^^^^^ previously declared here
  5 │   (@string_type extern))
    ·   ^^^^^^^^^^^^^^^^^^^^^
  6 │ 
  [128]

  $ wax twice.wax -f wat
  Error: The module already declares its 'string_imports'.
   ──➤  twice.wax:2:1
  1 │ #![string_imports = "str"]
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^ previously declared here
  2 │ #![string_imports = "str2"]
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^^
  3 │ 
  [128]

The text of a JavaScript string must be valid UTF-8, the encoding of an import
name:

  $ wax bad-utf8.wat -v -f wasm -o /dev/null
  Error: A JavaScript string must be a valid Unicode string.
   ──➤  bad-utf8.wat:3:44
  1 │ (module
  2 │   (@string_imports "str")
  3 │   (func (export "f") (result (ref extern)) (@string extern "\ff")))
    ·                                            ^^^^^^^^^^^^^^^^^^^^^^
  4 │ 
  [128]
