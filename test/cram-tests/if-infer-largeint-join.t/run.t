Inferring an `if`'s result type joins the branches' value types. A literal too
big for i32 has type "large number" (defaulting to i64), and `join_value_types`
had no case for it, so an `if` (or block) with one large-number branch and
another integer branch was rejected with "no common supertype". A large number
joins with another flexible integer (staying a large number) or with a concrete
i64/f32/f64.
Regression: found by the differential-validation fuzzer.

  $ cat > lj.wat <<'WAT'
  > (module
  >   (func (export "f") (result i64)
  >     (i64.add
  >       (if (result i64) (i32.const 1)
  >         (then (i64.const 5793170017578347395))
  >         (else (i64.const 7)))
  >       (i64.const 0))))
  > WAT

  $ wax -i wat -f wax lj.wat
  #[export = "f"]
  fn f() -> i64 {
      (if 1 {
           5793170017578347395;
       } else {
           7;
       } + 0);
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax lj.wat -o lj.wax && wax -i wax -f wasm lj.wax -o /dev/null --validate
