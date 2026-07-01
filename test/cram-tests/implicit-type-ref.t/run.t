A WAT module keeps an inline function-import signature anonymous (an implicit
type). Wax renders such a type inline where it can, but a ref-type position has
no inline function-type form — so when an implicit type is referenced from one,
it is materialised as a named [type] declaration on decompilation.

  $ wax ref.wat -f wax
  type t = fn(i32) -> i64;
  // An inline function-import signature synthesises an implicit type (index 0).
  #[import = ("env", "f")]
  fn f(i32) -> i64;
  // Referencing that implicit type from a ref-type position: Wax has no inline
  // function-type form here, so it is given a name and a `type` declaration.
  let g: &?t = null;

The materialised type round-trips back to the same module.

  $ wax ref.wat -f wasm -o ref.wasm
  $ wax ref.wasm -f wat
  (type (func (param i32) (result i64)))
  (import "env" "f" (func $f (param i32) (result i64)))
  (global (mut (ref null 0)) ref.null 0)
