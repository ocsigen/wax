Regression (differential-validation fuzzer, reduced): in dead code after a
`return_call`, a `br_on_cast` to `(ref null nofunc)` feeds a `call_ref`. `from_wasm`
discards the branch's source type, so the polymorphic fall-through residual is the
bottom function reference `(ref nofunc)`; the `as &?ft` cast that `call_ref`'s
decompilation adds then looks like a redundant up-cast (`nofunc <: ft`) and simplify
dropped it — leaving an uncallable `_()` (a `(ref nofunc)` receiver has no function
type to resolve, so the round-trip no longer type-checked). A cast of a bottom
reference to a concrete type of a non-`any` hierarchy is now load-bearing and kept:

  $ cat > f.wat <<'WAT'
  > (module
  >   (type $ft (func (result i32)))
  >   (func $h (result i32) i32.const 0)
  >   (func $f (result i32)
  >     (block $blk (result funcref)
  >       return_call $h
  >       br_on_cast $blk (ref null $ft) (ref null nofunc)
  >       call_ref $ft
  >       return)
  >     drop
  >     i32.const 0))
  > WAT
  $ wax -i wat -f wax f.wat
  type ft = fn() -> i32;
  fn h() -> i32 {
      0;
  }
  fn f() -> i32 {
      _ =
          'blk: do {
              become h();
              return ((br_on_cast 'blk &?nofunc _) as &?ft)();
          };
      0;
  }
  $ wax -i wat -f wax f.wat -o f.wax && wax -i wax -f wasm f.wax -o /dev/null --validate
