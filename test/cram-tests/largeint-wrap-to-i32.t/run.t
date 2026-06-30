An integer literal too big for i32 has type "large int" (it defaults to i64).
Casting it to i32 wraps it to the low 32 bits — the form produced when
decompiling `i32.wrap_i64` (or `i64.extend32_s`) applied to such a constant. This
previously failed with "This value of type int cannot be cast to the target
type." Regression: found by the differential-validation fuzzer.

  $ cat > lc.wat <<'WAT'
  > (module
  >   (func (export "f") (result i32)
  >     i64.const 70368744177664
  >     i32.wrap_i64))
  > WAT

  $ wax -i wat -f wax lc.wat
  #[export = "f"]
  fn f() -> i32 {
      70368744177664 as i32;
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax lc.wat -o lc.wax && wax -i wax -f wasm lc.wax -o /dev/null --validate
