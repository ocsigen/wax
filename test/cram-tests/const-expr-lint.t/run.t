The validator lints constant expressions too — a data/elem offset, a global or
field initializer — not just function bodies, so a redundant `0 + 42` in a data
offset is reported the same on WebAssembly input as on the equivalent Wax source
(where the type checker already lints it).

The parent `dune` sets `WAX_WARN=correctness=hidden`; `redundant-operation` is in
the (off-by-default) `redundant` group, so enable it explicitly:

  $ wax check -W redundant=warning offset.wat
  Warning [redundant-operation]: This operation has no effect on its result.
   ──➤  offset.wat:4:18
  2 │   (memory 1)
  3 │   (global $g (mut i32) (i32.const 0))
  4 │   (data (offset (i32.add (i32.const 0) (i32.const 42))) "x")
    ·                  ^^^^^^^
  5 │   (func (export "f") (result i32) (global.get $g)))
  6 │ 
