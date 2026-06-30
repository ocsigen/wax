The bottom reference &none belongs to the any hierarchy only, so a bare null's
non-null / branch fallback (&none) cannot stand in for a func/extern/exn/cont
null. The simplify pass therefore keeps the `as &?H` annotation on a null cast
to a non-any hierarchy (dropping it for any-hierarchy nulls, where &none is a
valid fallback). Here ref.null exn + ref.as_non_null must keep its &?exn so the
&exn result type-checks. Regression: found by the smith fuzzer (smith-284).

  $ cat > t.wat <<'WAT'
  > (module (func (export "f") (result (ref exn)) ref.null exn ref.as_non_null))
  > WAT
  $ wax -i wat -f wax t.wat
  #[export = "f"]
  fn f() -> &exn {
      (null as &?exn)!;
  }
  $ wax -i wat -f wax t.wat -o t.wax && wax -i wax -f wasm t.wax -o /dev/null --validate

An any-hierarchy null still drops to a bare null (the &none fallback suffices):

  $ cat > a.wat <<'WAT'
  > (module (func (export "f") (result (ref any)) ref.null any ref.as_non_null))
  > WAT
  $ wax -i wat -f wax a.wat | grep -c 'null!'
  1
