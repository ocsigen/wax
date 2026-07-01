br_on_cast_fail re-types its operand as the lub of the operand's type and the
cast target. When the target is a bottom reference (here [(ref none)], the
any-hierarchy bottom), that lub is just the operand's own type — but heap_lub
walked a concrete operand type up to its supertype before noticing the other side
was a bottom below it, over-generalising [lub(none, $t)] to [struct]. The branch
then delivered a [(ref struct)] to a label expecting [(ref null $t)] and the
recompile failed. heap_lub now resolves a bottom against its hierarchy first.
Regression: found by the differential-validation fuzzer.

  $ cat > m.wat <<'WAT'
  > (module
  >   (type $t (struct))
  >   (func (export "f") (param (ref null $t)) (result (ref null $t))
  >     (block $b (result (ref null $t))
  >       struct.new_default $t
  >       br_on_cast_fail $b (ref $t) (ref none)
  >       drop
  >       local.get 0)))
  > WAT

  $ wax -i wat -f wax m.wat
  type t = { };
  #[export = "f"]
  fn f(x: &?t) -> &?t {
      'b: do {
          _ = br_on_cast_fail 'b &none {t| .. };
          x;
      }
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax m.wat -o m.wax && wax -i wax -f wasm m.wax -o /dev/null --validate
