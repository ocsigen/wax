Regression (wasm-smith round-trip fuzzer, reduced): the control-flow analogue of
`drop-width-drift.t`. A value left on the stack when an unconditional branch
(`return`/`br`/`unreachable`/`become`/…) discards it is a live computation whose
result is thrown away — but, unlike an explicit `drop`, nothing pinned its
opcode width, so a bare numeric tree re-defaulted to i32 on re-parse. For a
width-sensitive op that silently narrowed the operation itself: here an `i64`
divisor `2147483648 + 2147483648` (which is `0` in i32 but `4294967296` in i64)
turned a *reachable* `i64.div_u` into an i32 divide-by-zero **trap** the original
never had.

`From_wasm` now pins such a leftover's width from its stack tag (in `push_poly`,
where an unconditional branch drops the rest of the stack), so the width survives:

  $ cat > m.wat <<'WAT'
  > (module (func (export "f") (result i64)
  >   i64.const 1
  >   i64.const 2147483648
  >   i64.const 2147483648
  >   i64.add
  >   i64.div_u
  >   i64.const 9
  >   return))
  > WAT
  $ wax -i wat -f wax m.wat
  #[export]
  fn f() -> i64 {
      (1 /u (2147483648 + 2147483648)) as i64;
      return 9;
  }

And it round-trips back to an `i64.div_u`, not a narrowed `i32.div_u`:

  $ wax -i wat -f wax m.wat -o m.wax && wax -i wax -f wasm m.wax -o out.wasm
  $ wasm-tools print out.wasm | grep -o 'i64.div_u'
  i64.div_u
