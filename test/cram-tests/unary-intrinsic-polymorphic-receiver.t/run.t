A unary intrinsic method (clz/ctz/popcnt/extend8_s/extend16_s, abs/ceil/floor/
trunc/nearest/sqrt, to_bits/from_bits) is resolvable from its name alone: the
method fixes the int/float family. So when its receiver is a fully-polymorphic
value taken off the stack of unreachable code (here a select of holes, of type
`_`), the receiver defaults to that family rather than failing with "Cannot
determine the type". Regression: found by the differential-validation fuzzer.

  $ cat > m.wat <<'WAT'
  > (module (func (export "f")
  >   unreachable
  >   select
  >   f64.floor
  >   drop))
  > WAT

  $ wax -i wat -f wax m.wat
  #[export]
  fn f() {
      unreachable;
      _ = (_?_:_).floor();
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax m.wat -o m.wax && wax -i wax -f wasm m.wax -o /dev/null --validate
