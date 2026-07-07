A `br_on_cast`/`br_on_cast_fail` carries two reference types: the source `rt1`
(the operand's type) and the cast target `rt2`, with `rt2 <: rt1`. The wax syntax
keeps only `rt2`; `to_wasm` recovers `rt1` from the operand. In unreachable code
(after a terminator) the operand is polymorphic and wax gives it the bottom
reference `(ref none)` — the wrong hierarchy for a target like `&struct`, so the
emitted `br_on_cast_fail rt1=(ref none) rt2=(ref struct)` failed its own
`rt2 <: rt1` check ("the first type must be a supertype of the second one").

`to_wasm` now discards that spurious bottom source and falls back to the cast
target, which is always a valid source (`rt2 <: rt2`):

  $ cat > b.wat <<'WAT'
  > (module
  >   (func (export "f") (result anyref)
  >     (block $l (result anyref)
  >       unreachable
  >       ref.as_non_null
  >       (br_on_cast_fail $l (ref any) (ref struct)))))
  > WAT
  $ wax -i wat -f wax b.wat
  #[export]
  fn f() -> &?any {
      'l: do {
          unreachable;
          br_on_cast_fail 'l &struct _!;
      }
  }
  $ wax -i wat -f wax b.wat -o b.wax && wax -i wax -f wasm b.wax -o /dev/null --validate
