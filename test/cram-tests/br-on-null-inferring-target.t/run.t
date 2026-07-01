br_on_null's fall-through carries the values below the reference through at the
branch target's parameter types. When that target is a block whose result is
still being inferred (the Wasm->Wax simplify pass), its parameter is a transient
Collecting inference cell; pushing it as a value type let a later `_` hole adopt
it, and the hole's operator then rejected the inference cell ("This operator
cannot be applied to operands of types ..."). The pass-through now resolves the
cell to the declared annotation. Regression: differential-validation fuzzer.

  $ cat > bon.wat <<'WAT'
  > (module
  >  (func (export "f") (param funcref) (result i32)
  >    (block (result i32)
  >      (i32.const 5)
  >      (local.get 0)
  >      (br_on_null 0)
  >      (drop)
  >      (i32.const 3)
  >      (i32.add))))
  > WAT

  $ wax -i wat -f wax bon.wat
  #[export = "f"]
  fn f(x: &?func) -> i32 {
      'l_2: do {
          br_on_null 'l_2 (5, x);
          _ = _;
          _ + 3;
      }
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax bon.wat -o bon.wax && wax -i wax -f wasm bon.wax -o /dev/null --validate
