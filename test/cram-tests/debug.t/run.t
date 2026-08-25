The --debug timing category logs the wall-clock running time of each compiler
pass to stderr, one line per pass as it finishes. The timing values vary from
run to run, so they are normalized here; only the labels and their order are
checked.

  $ wax input.wax -f wat --debug timing 2>&1 >/dev/null | sed 's/[0-9.]* ms/<t> ms/'
  parse: <t> ms
  type-check: <t> ms
  convert: <t> ms
  validate: <t> ms
  layout: <t> ms
  output: <t> ms

Categories are repeatable and may be comma-separated; an unknown category is
rejected with the list of valid ones.

  $ wax input.wax -f wat --debug bogus 2>&1 >/dev/null | tr '\n' ' ' | tr -s ' ' | grep -o 'Unknown debug category.*)'
  Unknown debug category: bogus (expected one of: timing, width-check, width-record)

The normal output on stdout is unchanged by --debug timing.

  $ wax input.wax -f wat > plain.wat
  $ wax input.wax -f wat --debug timing > debug.wat 2>/dev/null
  $ diff plain.wat debug.wat && echo identical
  identical

The width-record category is the recording-gap census: on a wasm/wat to wax
conversion it reports (to stderr) every value node the decompiler emitted
without recording the type its opcode states and without deliberately marking
the width as contextual. A clean toolchain reports nothing, dead code and all —
fuzz/width-record.sh sweeps the whole corpus for the same invariant; this pins
the interface and a shape from each historic gap class (a dead vector load, an
imported memory's size, a comparison, a narrow atomic RMW).

  $ cat > census.wat <<\WAT
  > (module
  >   (import "env" "mem" (memory 1))
  >   (global $z v128 (v128.const i64x2 0 0))
  >   (func (param i32) (result i32)
  >     (drop (v128.load (i32.const 0)))
  >     (memory.size)
  >     (return)
  >     (drop (i64.atomic.rmw8.sub_u (i32.const 0) (i64.const 1)))
  >     (drop (global.get $z))
  >     (i32.eq (local.get 0) (i32.const 5))))
  > WAT
  $ wax census.wat -f wax --debug width-record > census.wax
  $ wax census.wax -f wat > /dev/null && echo round-trips
  round-trips
