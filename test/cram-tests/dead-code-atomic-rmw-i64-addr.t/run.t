Regression (wasm-smith round-trip fuzzer, reduced): a narrow atomic RMW
(`rmw8`/`16`/`32`) or store on a memory64, in dead code, whose i64/i32 type is
chosen from its value operand — here a hole on the polymorphic dead-code stack.
`From_wasm` used to emit the operand anchor-free, so on re-parse it re-defaulted
to i32, silently narrowing `i64.atomic.rmw8.sub_u` to the i32 form; when the
RMW's i64 result then feeds a memory64 address (`i64.atomic.load16_u` here), the
recompile failed with "produces i32, but i64 expected". `From_wasm` now pins the
value operand to `i64`, so the width survives and the module round-trips:

  $ cat > f.wat <<'WAT'
  > (module
  >   (memory i64 1)
  >   (func
  >     unreachable
  >     i64.atomic.rmw8.sub_u
  >     i64.atomic.load16_u
  >     drop))
  > WAT
  $ wax -i wat -f wax f.wat
  memory m: i64 [1];
  fn f() {
      unreachable;
      _ = m.atomic_load16(m.atomic_rmw_sub8(_, _ as i64)) as i64_u;
  }
  $ wax -i wat -f wax f.wat -o f.wax && wax -i wax -f wasm f.wax -o /dev/null --validate
