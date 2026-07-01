Regression (differential-validation fuzzer, reduced): `any.convert_extern;
ref.cast (ref any)` on a nullable `externref` — converting to the `any` hierarchy,
then a non-null cast. `from_wasm` makes this `(e as &?any) as &any`, which simplify
fuses to `e as &any` on the `&?extern`. Two bugs surfaced.

First, the cast type-checker rejected `&?extern as &any`: its extern/any
cross-hierarchy arms tested the operand against the target's nullability, so a
nullable operand cast to a non-null target failed. The `ref.cast` handles
nullability, so hierarchy membership is now tested against a nullable reference (as
the general cross-hierarchy arm already did).

Second, `to_wasm` then emitted only `any.convert_extern` (a nullable result) for
the non-null `&any` target, dropping the null check. From a nullable operand it now
emits the trailing `ref.cast (ref any)`; a non-null operand already converts to a
non-null `any`, so it stays a bare convert (see the `jsstring` round-trip).

  $ cat > f.wat <<'WAT'
  > (module
  >   (table 1 externref)
  >   (func (result (ref any))
  >     i32.const 0
  >     table.get 0
  >     any.convert_extern
  >     ref.cast (ref any)))
  > WAT
  $ wax -i wat -f wax f.wat
  table t: &?extern [1];
  fn f() -> &any {
      t[0] as &any;
  }
  $ wax -i wat -f wax f.wat -o f.wax && wax -i wax -f wasm f.wax -o /dev/null --validate
