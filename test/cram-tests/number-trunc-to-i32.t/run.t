The only numeric -> i32 signed cast is a float truncation (i32.trunc_f*_s), so a
flexible `number` source (here `-(_ * _)`, an abstract product in unreachable
code) is a float and defaults to f64 — like the `float` case. It used to be
rejected with "This value of type number cannot be cast to the target type".
(An `int` source stays rejected: there is no integer -> i32 signed conversion.)
Regression: found by the differential-validation fuzzer.

  $ cat > m.wat <<'WAT'
  > (module (func (export "f") (result i32)
  >   unreachable
  >   f32.mul
  >   f32.neg
  >   i32.trunc_f32_s))
  > WAT

  $ wax -i wat -f wax m.wat
  #[export = "f"]
  fn f() -> i32 {
      unreachable;
      -(_ * _) as i32_s_strict;
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax m.wat -o m.wax && wax -i wax -f wasm m.wax -o /dev/null --validate
