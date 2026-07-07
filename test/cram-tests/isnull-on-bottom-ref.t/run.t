`!` is `i32.eqz` on an integer and `ref.is_null` on a reference. Applied to a
bottom reference (`UnknownRef`, e.g. the result of `ref.as_non_null` on a
polymorphic value in unreachable code), it is the `ref.is_null` reading, but the
operator-type check only accepted i32/i64/ref/null/int, not `UnknownRef`, so it
failed with "This instruction has type &_ but is expected to have type int".
Regression: found by the differential-validation fuzzer.

  $ cat > in.wat <<'WAT'
  > (module
  >   (func (export "f") (result i32)
  >     unreachable
  >     ref.as_non_null
  >     ref.is_null))
  > WAT

  $ wax -i wat -f wax in.wat
  #[export]
  fn f() -> i32 {
      unreachable;
      !_!;
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax in.wat -o in.wax && wax -i wax -f wasm in.wax -o /dev/null --validate
