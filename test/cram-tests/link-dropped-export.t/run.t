Linking without dead code elimination while dropping exports (through
`rename_export`, here with the `link_filter` test driver, which keeps the listed
exports). A function referenced by `ref.func` in a function body must remain
declared when the export which declared it is dropped: it is then declared in a
declarative segment.

In this module, `main` returns `call_ref (ref.func $h)` and `$h` is exported.
There is no element segment, which `wax` would add, so the module is written
directly in binary:
  $ printf '\000asm\001\000\000\000\001\005\001`\000\001\177\003\003\002\000\000\007\014\002\001h\000\000\004main\000\001\012\015\002\004\000A\006\013\006\000\322\000\024\000\013' > nodecl.wasm
  $ wax nodecl.wasm -f wat
  (type (func (result i32)))
  (func (result i32)
    i32.const 6
  )
  (func (result i32)
    ref.func 0
    call_ref 0
  )
  (export "h" (func 0))
  (export "main" (func 1))
  $ ../../link-filter/link_filter.exe out.wasm main a:nodecl.wasm
  $ wax check out.wasm
  $ wax out.wasm -f wat
  (type (func (result i32)))
  (func (result i32)
    i32.const 6
  )
  (func (result i32)
    ref.func 0
    call_ref 0
  )
  (export "main" (func 1))
  (elem declare func 0)
