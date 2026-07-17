A narrow i64 store (`i64.store8`/`store16`/`store32`) takes an i64 value, but the
store method name only records the access width, not the value's i32/i64 type --
that is recovered from the value operand on re-parse. When the value is a
width-flexible expression the decompiler must pin it to i64 (as the atomic narrow
stores already do), or the round trip re-defaults it to i32 and the wrapped byte
changes.

  $ cat > st.wat <<'WAT'
  > (module (memory 1)
  >   (func (i64.store8 (i32.const 0) (i64.shr_u (i64.const 4096) (i64.const 40)))))
  > WAT

  $ wax -i wat -f wax st.wat
  memory m: i32 [1];
  fn f() {
      m.store8(0, (4096 >>u 40) as i64);
  }

The i64 shift survives the round trip -- an i32 shift would mask the count 40 to
8 and store 16 instead of 0:

  $ wax -i wat -f wax st.wat | wax -i wax -f wat
  (memory $m 1)
  (func $f
    (i64.store8 $m (i32.const 0) (i64.shr_u (i64.const 4096) (i64.const 40)))
  )
