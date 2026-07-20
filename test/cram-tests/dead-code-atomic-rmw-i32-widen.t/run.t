Regression (wasm-smith round-trip fuzzer, reduced): an i32 atomic RMW
(`rmw`/`rmw8`/`rmw16`) picks its i32/i64 family from its value operand, and the
RMW's result (the returned old value) takes that same type. The typer used to
leave an `Unknown` value operand (a hole on the polymorphic dead-code stack)
untyped, so the RMW *result* stayed `Unknown` too. Unlike a flexible literal tree
(which `To_wasm` re-parses at a cast's width), the RMW is a concrete op, so a
widening `i64.extend_i32_u` on its `Unknown` result (decompiled as
`(m.atomic_rmw_add32(..) as i64_u)`) had no source type: `To_wasm` dropped the
cast and fed the concrete i32 result to `i64.clz`, so a module the typer accepted
failed to convert with "produces i32, but i64 expected".

The typer now types a narrow RMW's result as the flexible `Int` rather than
`Unknown`. It defaults to i32 (so this widening cast becomes a real extend), yet
a consumer can still pin it to i64 (see `dead-code-atomic-rmw-i64-addr.t`). This
is a soundness fix on the typer itself, not the decompiler: the hand-written Wax
below type-checks *and* converts.

  $ cat > f.wat <<'WAT'
  > (module
  >   (memory i64 1 10 shared)
  >   (func
  >     unreachable
  >     i32.atomic.rmw.add
  >     i64.extend_i32_u
  >     i64.clz
  >     drop))
  > WAT
  $ wax -i wat -f wax f.wat
  memory m: i64 [1, 10] shared;
  fn f() {
      unreachable;
      _ = (m.atomic_rmw_add32(_, _) as i64_u).clz();
  }
  $ wax -i wat -f wax f.wat -o f.wax && wax -i wax -f wasm f.wax -o /dev/null --validate

The decompiled Wax also type-checks and converts on its own (the soundness
property — `check` accepting must imply a successful lowering):

  $ wax -i wat -f wax f.wat -o f.wax && wax check f.wax && wax -f wat f.wax > /dev/null
