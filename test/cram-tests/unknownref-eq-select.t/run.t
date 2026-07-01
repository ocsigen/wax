A bottom reference (UnknownRef, e.g. ref.as_non_null of a polymorphic value in
unreachable code) is a valid operand of ref.eq and of a (reference) select. The
operator/lub checks didn't account for it: ref.eq rejected it, and select's
result lub kept Unknown instead of the more informative UnknownRef (so it lowered
to an untyped, numeric-only select). Both are now handled. Regression: found by
the differential-validation fuzzer.

ref.eq on two bottom references:

  $ cat > eq.wat <<'WAT'
  > (module (func (export "f") (result i32)
  >   unreachable ref.as_non_null ref.as_non_null ref.eq))
  > WAT
  $ wax -i wat -f wax eq.wat
  #[export = "f"]
  fn f() -> i32 {
      unreachable;
      _ == _!!;
  }
  $ wax -i wat -f wax eq.wat -o eq.wax && wax -i wax -f wasm eq.wax -o /dev/null --validate

A select whose result joins a polymorphic value with a bottom reference is a
typed (reference) select, not an untyped one:

  $ cat > sel.wat <<'WAT'
  > (module (func (export "f") (param i32) (result anyref)
  >   unreachable ref.as_non_null ref.as_non_null local.get 0 select (result anyref)))
  > WAT
  $ wax -i wat -f wax sel.wat
  #[export = "f"]
  fn f(x: i32) -> &?any {
      unreachable;
      x?_:_!!;
  }
  $ wax -i wat -f wax sel.wat -o sel.wax && wax -i wax -f wasm sel.wax -o /dev/null --validate

When both select operands are bottom references and the result type comes from the
context (here a func-hierarchy result), the two are merged and pinned to that
hierarchy, rather than resolving to the default any-hierarchy `&none`:

  $ cat > fsel.wat <<'WAT'
  > (module (func (export "f") (param i32) (result funcref)
  >   unreachable ref.as_non_null ref.as_non_null local.get 0 select (result funcref)))
  > WAT
  $ wax -i wat -f wax fsel.wat
  #[export = "f"]
  fn f(x: i32) -> &?func {
      unreachable;
      x?_:_!!;
  }
  $ wax -i wat -f wax fsel.wat -o fsel.wax && wax -i wax -f wasm fsel.wax -o /dev/null --validate
