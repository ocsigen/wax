Regression (wasm-smith round-trip fuzzer, reduced): a narrow atomic RMW
(`rmw8`/`16`/`32`) picks its i32/i64 type from its value operand — here a hole on
the polymorphic dead-code stack. The typer used to leave such an operand (and so
the RMW's result, the returned old value) `Unknown`; `To_wasm` then lowered the
i64 op at its i32 default, and when the result fed a memory64 address
(`i64.atomic.load16_u` here) the recompile failed with "produces i32, but i64
expected".

The typer now types a narrow RMW's result as the flexible `Int` rather than
`Unknown`: it defaults to i32 like any flexible integer, yet a consumer can pin
it — here the i64 memory address pins it back to i64 — so the module round-trips
with no `From_wasm` width-pin needed:

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
      _ = m.atomic_load16(m.atomic_rmw_sub8(_, _)) as i64_u;
  }
  $ wax -i wat -f wax f.wat -o f.wax && wax -i wax -f wasm f.wax -o /dev/null --validate
