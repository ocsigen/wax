A function marked #[start] runs at module instantiation. It compiles to a
Wasm (start ...) field:

  $ wax -i wax -f wat start.wax
  (func $init (nop))
  (start $init)

Conversely, a Wasm start function becomes a #[start] attribute:

  $ wax -i wat -f wax start.wat
  #[start]
  fn init() {}

The start function must have no parameters and no results:

  $ wax check bad-signature.wax
  Error: The start function must have no parameters and no results.
   ──➤  bad-signature.wax:1:13
  1 │ #[start] fn main() -> i32 { return 0 as i32; }
    ·             ^^^^
  2 │ 
  [128]

A module may have at most one start function:

  $ wax check two-starts.wax
  Error: A module can have at most one start function.
   ──➤  two-starts.wax:2:1
  1 │ #[start] fn f() {}
  2 │ #[start] fn g() {}
    · ^^^^^^^^^^^^^^^^^^
  3 │ 
  [128]
