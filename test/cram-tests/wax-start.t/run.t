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
    · ^^^^^^^^^^^^^^^^^^ other start function here
  2 │ #[start] fn g() {}
    · ^^^^^^^^^^^^^^^^^^
  3 │ 
  [128]

An imported function may be the start function; the #[start] attribute
round-trips through the import (rather than being silently dropped):

  $ cat > import-start.wat <<'WAT'
  > (module (import "m" "f" (func $f)) (start $f))
  > WAT

  $ wax -i wat -f wax import-start.wat
  import "m"
  #[start]
  fn f();

  $ wax -i wat -f wax import-start.wat | wax -i wax -f wat
  (import "m" "f" (func $f))
  (start $f)

An imported start function must also have no parameters and no results:

  $ cat > bad-import-start.wax <<'WAX'
  > import "m" #[start] fn f(i32);
  > WAX
  $ wax check bad-import-start.wax
  Error: The start function must have no parameters and no results.
   ──➤  bad-import-start.wax:1:24
  1 │ import "m" #[start] fn f(i32);
    ·                        ^
  2 │ 
  [128]
