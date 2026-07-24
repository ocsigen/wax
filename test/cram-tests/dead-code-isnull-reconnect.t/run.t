Regression (wasm-smith round-trip fuzzer): a `ref.is_null` in unreachable code
whose operand springs from the polymorphic bottom, but with a value and a
transparent statement interposed between the bottom and the `ref.is_null`. The
value above (an `i32.const`, an `i32.atomic.rmw` result) is the condition a
following `br_if` consumes; `atomic.fence` sits between them with no stack effect.
`ref.is_null` lowers to the Wax `!` surface (shared with `i32.eqz`), so a bare
`!_` re-parses to `i32.eqz` unless pinned. The pin must fire here: the operand is
the bottom, not the interposed value.

`From_wasm`'s `effective_backing` looks through the interposed entries to decide.
It skips a zero-value statement (the `br_if`, the `fence`) and a numeric value
residual (the `i32.const`, the tagged `atomic.rmw` result: a number can never be
a `ref.is_null` operand, so it is a leftover from a grab an interposed statement
blocked, not what the op pops), reaching the terminator sentinel and pinning
`(_ as &?any)`. A genuine reference residual instead backs a bare `!_`
(dead-code-flexible-result.t relies on that: a `&nofunc` `br_on_cast` fall-through
must stay bare).

  $ cat > m.wat <<'WAT'
  > (module (memory 1 1 shared)
  >   (func $const_between (param i32)
  >     (block $l
  >       unreachable
  >       i32.const 7
  >       atomic.fence
  >       br_if $l
  >       ref.is_null
  >       drop))
  >   (func $rmw_between (param i32)
  >     (block $l
  >       unreachable
  >       i32.const 0 i32.const 5 i32.atomic.rmw.add
  >       atomic.fence
  >       br_if $l
  >       ref.is_null
  >       drop)))
  > WAT
  $ wax -i wat -f wax --faithful m.wat
  memory m: i32 [1, 1] shared;
  fn const_between(i32) {
      'l: do {
          unreachable;
          7;
          atomic::fence();
          br_if 'l _;
          _ = !(_ as &?any);
      }
  }
  fn rmw_between(i32) {
      'l: do {
          unreachable;
          m.atomic_rmw_add32(0, 5);
          atomic::fence();
          br_if 'l _;
          _ = !(_ as &?any);
      }
  }

The round trip keeps `ref.is_null`, not a re-defaulted `i32.eqz`:

  $ wax -i wat -f wax --faithful m.wat -o m.wax && wax -i wax -f wasm m.wax -o m.wasm
  $ wax -i wasm -f wat m.wasm | grep -oE 'ref.is_null|i32.eqz'
  ref.is_null
  ref.is_null
