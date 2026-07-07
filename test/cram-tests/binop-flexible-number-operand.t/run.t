A numeric binary operator whose left operand is a fully-flexible `number` literal
and whose right operand is a more committed flexible integer (`int`) used to be
rejected: the operand matches covered `(int, number)` but not the symmetric
`(number, int)`. Such pairs arise in dead code, where a decompiled constant stays
flexible. The numeric binop checks are now routed through shared helpers
(`check_num_concrete` / `check_int_bin_op` / `check_float_bin_op`) that cover both
orders. Regression: found by the differential-validation fuzzer.

  $ cat > m.wat <<'WAT'
  > (module (func (export "f")
  >   unreachable
  >   i32.const 1
  >   i32.const 2
  >   i32.extend8_s
  >   i32.mul
  >   drop))
  > WAT

  $ wax -i wat -f wax m.wat
  #[export]
  fn f() {
      unreachable;
      _ = 1 * (2).extend8_s();
  }

And it round-trips back to valid wasm:

  $ wax -i wat -f wax m.wat -o m.wax && wax -i wax -f wasm m.wax -o /dev/null --validate
