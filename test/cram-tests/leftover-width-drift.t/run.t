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

And it round-trips through the binary encoder back to an `i64.div_u`, not a
narrowed `i32.div_u` (decoding the `.wasm` with `wax` itself, so the test needs
no external tooling):

  $ wax -i wat -f wax m.wat -o m.wax && wax -i wax -f wasm m.wax -o out.wasm
  $ wax -i wasm -f wat out.wasm | grep -o 'i64.div_u'
  i64.div_u

The *conditional*-branch analogue: a width-op result left on the stack past a
`br_if` (or `br_on_null`/`br_on_cast`/…) is not covered by the `push_poly` pin
above, because a conditional branch is not a terminator — it pushes a statement
entry on top of the leftover, which buries it so no later consumer (nor the
width-erasing `drop` here) can reach it. `Stack.run` now pins such a stranded
value from its discarded tag. Without the pin an `i64.shr_u` narrowed to
`i32.shr_u` (`4096 >>u 40` is `0` in i64 but `16` in i32):

  $ cat > c.wat <<'WAT'
  > (module (func (export "f") (param $c i32)
  >   (block $l
  >     i64.const 4096
  >     i64.const 40
  >     i64.shr_u
  >     local.get $c
  >     br_if $l
  >     drop)))
  > WAT
  $ wax -i wat -f wax c.wat
  #[export]
  fn f(c: i32) {
      'l: do {
          (4096 >>u 40) as i64;
          br_if 'l c;
          _ = _;
      }
  }
  $ wax -i wat -f wax c.wat -o c.wax && wax -i wax -f wasm c.wax -o c.wasm
  $ wax -i wasm -f wat c.wasm | grep -o 'i64.shr_u'
  i64.shr_u

The same shape with a float method, where the drift is a precision change
(`f32.sqrt` re-defaulting its bare-literal operand to `f64.sqrt`):

  $ cat > s.wat <<'WAT'
  > (module (func (export "f") (param $c i32)
  >   (block $l
  >     f32.const 0x1.5p+1
  >     f32.sqrt
  >     local.get $c
  >     br_if $l
  >     drop)))
  > WAT
  $ wax -i wat -f wax s.wat -o s.wax && wax -i wax -f wasm s.wax -o s.wasm
  $ wax -i wasm -f wat s.wasm | grep -o 'f32.sqrt'
  f32.sqrt
