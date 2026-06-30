In unreachable code the operand stack is polymorphic, so an instruction like
`f64.min` may take an operand of no determined type. A method-form intrinsic
(`min`/`max`/`copysign`, `rotl`/`rotr`) type-checks its operands strictly, so the
decompiler pins a non-inlinable operand to the operator's scalar type with a cast
— `(_ as f64).min(..)` — exactly as it already does for the unary ops. Without
the cast this failed with "This operator cannot be applied to operands of types
any and float." Regression: found by the differential-validation fuzzer.

  $ cat > dm.wat <<'WAT'
  > (module
  >   (func (export "f") (result f64)
  >     unreachable
  >     f64.const 1
  >     f64.min))
  > WAT

  $ wax -i wat -f wax dm.wat
  #[export = "f"]
  fn f() -> f64 {
      unreachable;
      (_ as f64).min(1);
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax dm.wat -o dm.wax && wax -i wax -f wasm dm.wax -o /dev/null --validate
