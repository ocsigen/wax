Three siblings of the smith-468 reconnection class (see
dead-code-isnull-reconnect.t), found by fuzz/backing-scan.sh's first run — each
a divergence between `effective_backing`'s model of the Wax re-parse and the
re-parse itself, in dead code, so the blast radius is round-trip fidelity, not
behaviour.

1. A cross-hierarchy convert's source pin must consult the backing scan. The
convert pins its absent operand (`(_ as &?extern)`) so the opcode survives a
bottom-sprung hole — but here an extern residual backs the hole: the printed
hole reconnects to it, so the pin would land on that real value and materialise
as a `ref.cast` the source never had. Left bare, the convert's own `as` surface
lowers over the reconnected value, one opcode, exactly the source:

  $ cat > cvt.wat <<'WAT'
  > (module
  >   (func
  >     unreachable
  >     ref.null none
  >     extern.convert_any
  >     atomic.fence
  >     any.convert_extern
  >     drop))
  > WAT
  $ wax -i wat -f wax --faithful cvt.wat
  fn f() {
      unreachable;
      null as &?none as &?extern;
      atomic::fence();
      _ = _ as &?any;
  }
  $ wax -i wat -f wax --faithful cvt.wat -o cvt.wax && wax cvt.wax -f wat | grep -coE 'ref.cast|ref.test' ; wax cvt.wax -f wat | grep -cE 'convert'
  0
  2

2. An all-numeric multi-value call residual is not a reference backing. The
expectation channel is single-valued, so nothing recorded that a two-i64 result
holds no reference; read as `Backing`, the dead `ref.is_null`'s hole was left
bare — and on the re-parse the pair was consumed by the earlier holes and the
bare `!_` re-defaulted to `i32.eqz`. Recording the first result of an
all-non-reference signature marks the node numeric for the scan, so the hole is
pinned and the opcode survives:

  $ cat > multi.wat <<'WAT'
  > (module
  >   (func $f2 (result i64 i64) (i64.const 1) (i64.const 2))
  >   (func (local $l i64)
  >     unreachable
  >     call $f2
  >     i64.add
  >     local.set $l
  >     ref.is_null
  >     drop))
  > WAT
  $ wax -i wat -f wax --faithful multi.wat -o multi.wax && wax multi.wax -f wat | grep -oE 'ref.is_null|i32.eqz'
  ref.is_null

3. A value `Stack.consume` already gave to a block-shaped consumer cancels
against that consumer's parameter claim. Here the block's `(param externref)`
takes the null; charging the parameter AGAIN made the claim eat the extern
residual below it, and the scan pinned the `ref.is_null` hole `(_ as &?any)`
over the very extern it in fact reconnects to — an `any.convert_extern` the
source never had:

  $ cat > consumed.wat <<'WAT'
  > (module
  >   (func
  >     unreachable
  >     ref.null none
  >     extern.convert_any
  >     ref.null extern
  >     block (param externref)
  >     drop
  >     end
  >     ref.is_null
  >     drop))
  > WAT
  $ wax -i wat -f wax --faithful consumed.wat -o consumed.wax && wax consumed.wax -f wat | grep -oE 'ref.is_null|i32.eqz|any.convert_extern|extern.convert_any'
  extern.convert_any
  ref.is_null
