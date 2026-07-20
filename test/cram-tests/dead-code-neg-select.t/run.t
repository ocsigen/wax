Regression (wasm-smith round-trip fuzzer, reduced): a float negation
(`f32.neg`/`f64.neg`) in dead code whose operand is a value with no committed
type — here a bare `select` of holes on the polymorphic dead-code stack, which
types as the flexible bottom `Unknown`.

The typer used to give `-e` on an `Unknown` operand a *fresh* `Number` result
cell, disconnected from the operand's cell. A later pin on the result (the
`f64.promote_f32` below, decompiled as an `as f64` consuming the negation) then
resolved the result to a float while the operand stayed `Unknown` — so `To_wasm`
lowered the operand at its i32 default (`i32.sub`) but annotated the result as
the pinned width, dropping the promote and feeding an i32 where f64 was expected:
"produces i32, but f64 expected". The typer now unifies the negation's result
with the operand's own cell (as `+`/`-`/`*` and a committed operand already do),
so pinning the result pins the operand and the negation lowers coherently:

  $ cat > f.wat <<'WAT'
  > (module
  >   (func
  >     unreachable
  >     select
  >     f32.neg
  >     f64.promote_f32
  >     drop))
  > WAT
  $ wax -i wat -f wax f.wat
  fn f() {
      unreachable;
      _ = -(_?_:_) as f64;
  }
  $ wax -i wat -f wax f.wat -o f.wax && wax -i wax -f wasm f.wax -o /dev/null --validate
