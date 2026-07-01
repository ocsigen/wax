A narrowing integer store (store8/store16/store32) wraps its value, so it accepts
an i64-wide value — including a literal too big for i32, of type "large number".
The store-value check accepted i32/i64/int/number but not "large number", so this
failed to decompile with "This instruction has type int but is expected to have
type int". Regression: found by the differential-validation fuzzer.

  $ cat > st.wat <<'WAT'
  > (module
  >   (memory 1)
  >   (func (export "f")
  >     i32.const 0
  >     i64.const 5793170017578347395
  >     i64.store8))
  > WAT

  $ wax -i wat -f wax st.wat
  memory m: i32 [1];
  #[export = "f"]
  fn f() {
      m.store8(0, 5793170017578347395);
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax st.wat -o st.wax && wax -i wax -f wasm st.wax -o /dev/null --validate
