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
residual (the `i32.const`, the tagged `atomic.rmw` result, the *numeric local*
read: a number can never be a `ref.is_null` operand, so it is a leftover from a
grab an interposed statement blocked, not what the op pops), reaching the
terminator sentinel and pinning `(_ as &?any)`. A local read is the case a tag
cannot catch, since a `local.get` states no type of its own: its type lives in
its declaration, so `From_wasm` records it on the node (see `local_valtypes` /
`global_valtypes`), which is how a numeric one is told from a reference one here.
A global read is the same case, and is covered too. A genuine reference residual instead backs a bare `!_`
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
  >       drop))
  >   (func $local_between (param i32)
  >     (local $i i32)
  >     (block $l
  >       unreachable
  >       local.get $i
  >       atomic.fence
  >       br_if $l
  >       ref.is_null
  >       drop))
  >   (global $g (mut i32) (i32.const 0))
  >   (func $global_between (param i32)
  >     (block $l
  >       unreachable
  >       global.get $g
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
  fn local_between(i32) {
      'l: do {
          unreachable;
          let i: i32;
          i;
          atomic::fence();
          br_if 'l _;
          _ = !(_ as &?any);
      }
  }
  let g: i32 = 0;
  fn global_between(i32) {
      'l: do {
          unreachable;
          g;
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
  ref.is_null
  ref.is_null

The opposite direction, where the scan must NOT stop: a statement that carries a
hole normally blocks it, because on a re-parse that hole claims the first value
above the statement, so the value cannot also back a later hole. But a hole the
re-parse types NUMERICALLY claims no reference. Here `data.drop` sits between the
`i32.const` and the `local.set`, so the set's operand is not popped in the
conversion's stack model and it prints as `x = _` — while in the Wasm the set
really does consume that `i32.const` and the `ref.null func` below stays for the
`ref.is_null`.

  $ cat > typed.wat <<'WAT'
  > (module
  >   (data "a")
  >   (func (param i32)
  >     unreachable
  >     ref.null func
  >     i32.const 1
  >     data.drop 0
  >     local.set 0
  >     ref.is_null
  >     drop))
  > WAT

Read as a blocker, that `x = _` made the `ref.is_null` look bottom-sprung and it
was pinned `(_ as &?any)` — but the hole DID reconnect, to the func-hierarchy
value, and the pin crossed hierarchies: the decompiled Wax did not type-check at
all (`wax check` accepted the wat, the conversion rejected its own output — a
wat-mutation-fuzzer finding). The value a set writes to a numeric local records
that local's type, exactly as a `local.get` does, so the statement stays
transparent and `!_` is left bare to reconnect:

  $ wax -i wat -f wax typed.wat
  data d = "a";
  fn f(x: i32) {
      unreachable;
      null as &?func;
      1;
      d.drop();
      x = _;
      _ = !_;
  }

  $ wax -i wat -f wax typed.wat -o typed.wax && wax typed.wax -f wat | grep -oE 'ref.is_null|i32.eqz'
  ref.is_null
