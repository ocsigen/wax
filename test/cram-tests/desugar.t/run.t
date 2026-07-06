`--desugar` expands the Wax-specific `(@string …)` and `(@char …)` annotations
into core WebAssembly (`array.new_fixed` / `i32.const`), producing plain text
other tools accept. An `i8` string keeps its raw UTF-8 bytes and an `i16` one is
UTF-16-encoded. An untyped string reuses an existing `(array (mut i8))` type
when the module has one (here `$b`), and otherwise pins a synthesised `<string>`
type. A module-level `(@string …)` global becomes an ordinary global:

  $ wax m.wat -f wat --desugar
  (type $w (array (mut i16)))
  (type $b (array (mut i8)))
  (global $sg (ref $b) (array.new_fixed $b 2 (i32.const 104) (i32.const 105)))
  (func (export "ch") (result i32)
    i32.const 128512
  )
  (func (export "s") (result (ref $b))
    (array.new_fixed $b 2 (i32.const 121) (i32.const 111))
  )
  (func (export "w") (result (ref $w))
    (array.new_fixed $w 3 (i32.const 233) (i32.const 55357) (i32.const 56832))
  )

The result is well-formed core wasm — no Wax annotations remain, so it compiles:

  $ wax m.wat -f wat --desugar -o desugared.wat && wax desugared.wat -f wasm -v -o /dev/null && echo ok
  ok

A conditional-compilation directive must be resolved (with `-D`) before
desugaring, since there is no core-wasm form for it:

  $ wax cond.wat -f wat --desugar -D DEBUG=true
  (func (export "f") (result i32) (i32.const 1))

An unresolved `(@if …)` makes desugaring fail:

  $ wax cond.wat -f wat --desugar
  Error:
    A conditional annotation cannot be desugared to plain WebAssembly text.
   ──➤  cond.wat:3:5
  1 │ (module
  2 │   (func (export "f") (result i32)
  3 │     (@if $DEBUG (@then (i32.const 1)) (@else (i32.const 0)))))
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │ 
  Hint: Resolve the conditionals with -D/--define.
  [128]

`--desugar` only applies to wat output:

  $ wax m.wat -f wax --desugar
  --desugar is only supported for wat output
  [123]
