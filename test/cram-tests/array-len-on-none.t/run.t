array.len accepts a [(ref null array)] receiver. [none] is the bottom of the
[any] hierarchy, so [(ref none)] is a subtype of it: the Wasm validator accepts
array.len on a [(ref none)] (it always traps at run time). wax used to reject
the corresponding [.length()] on a [&none] receiver as an invalid method
receiver. Regression: found by the differential-validation fuzzer.

  $ cat > m.wat <<'WAT'
  > (module (func (export "f") (result i32)
  >   ref.null none
  >   ref.cast (ref none)
  >   array.len))
  > WAT

  $ wax -i wat -f wax m.wat
  #[export = "f"]
  fn f() -> i32 {
      (null as &?none as &none).length();
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax m.wat -o m.wax && wax -i wax -f wasm m.wax -o /dev/null --validate
