A function referenced by ref.func only inside a function body is not, on its
own, declared as referenceable, so the module would fail strict reference
validation. Compiling wat to the binary format adds a declarative element
segment for such functions; here $f gets one, and the round-trip back to text
shows it.

  $ wax -i wat -f wasm reffunc.wat -o reffunc.wasm
  $ wax -i wasm -f wat reffunc.wasm
  (type (func))
  (func $f)
  (func ref.func $f
        drop)
  (export "g" (func 1))
  (elem declare func $f)
