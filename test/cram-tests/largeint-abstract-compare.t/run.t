A comparison between an abstract operand (the polymorphic value of unreachable
code) and a literal too big for i32 — a "large number", defaulting to i64 — was
rejected with "This operator cannot be applied to operands of types int and
int." The one-abstract path of the arithmetic checker accepted `int` but not
`large number`, though the both-concrete path already did. Regression: found by the
differential-validation fuzzer.

  $ cat > lic.wat <<'WAT'
  > (module
  >   (func (export "f") (result i32)
  >     unreachable
  >     i64.const 5793170017578347395
  >     i64.le_u))
  > WAT

  $ wax -i wat -f wax lic.wat
  #[export]
  fn f() -> i32 {
      unreachable;
      _ <=u 5793170017578347395;
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax lic.wat -o lic.wax && wax -i wax -f wasm lic.wax -o /dev/null --validate
