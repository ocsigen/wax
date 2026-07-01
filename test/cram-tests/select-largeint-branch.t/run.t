A select's result type is the join of its two branches. The select typing had its
own copy of the join that, unlike join_value_types, lacked the large-int cases,
so a select between a literal too big for i32 and another integer failed with
"The two branches of this select have no common supertype". Select now reuses
join_value_types. Regression: found by the differential-validation fuzzer.

  $ cat > sli.wat <<'WAT'
  > (module (func (export "f") (param i32) (result i64)
  >   (select (i64.const 5793170017578347395) (i64.const 1) (local.get 0))))
  > WAT

  $ wax -i wat -f wax sli.wat
  #[export = "f"]
  fn f(x: i32) -> i64 {
      x?5793170017578347395:1;
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax sli.wat -o sli.wax && wax -i wax -f wasm sli.wax -o /dev/null --validate
