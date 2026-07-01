Regression (differential-validation fuzzer, reduced): a float `min`/`max`/`copysign`
(or int `rotl`/`rotr`) in dead code with a polymorphic operand — here `x.min(y)`
where `y` is a bare `select` of two holes, which stays `Unknown`. Unlike the `BinOp`
form (`+`, `-`, comparisons), whose typing has explicit abstract-operand arms,
`type_binary_intrinsic_call` called `check_float_bin_op` directly — and that helper
leaves the `Unknown`/`Error` cases to its caller, so an `(f64, Unknown)` pair was
rejected as "f64 and any". The intrinsic path now resolves an abstract operand onto
the other's type, so it decompiles and round-trips:

  $ cat > f.wat <<'WAT'
  > (module
  >   (func $f (result f64)
  >     unreachable
  >     i32.const 586924054
  >     select
  >     f64.min))
  > WAT
  $ wax -i wat -f wax f.wat
  fn f() -> f64 {
      unreachable;
      (_ as f64).min(586924054?_:_);
  }
  $ wax -i wat -f wax f.wat -o f.wax && wax -i wax -f wasm f.wax -o /dev/null --validate
