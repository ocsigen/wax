A flexible numeric literal that is the fall-through of a try/loop block whose
result type is being synthesized must take the block's inferred width. Here the
block result is pinned to f32 (by the i32.reinterpret_f32 / .to_bits() consumer
and a branch carrying an f32), so the trailing 0x1p-136 must compile to an f32
const, not its default f64 — otherwise the block body produces an f64 where the
block's result type is f32, and the emitted module fails to validate. Unlike a
do block (whose fall-through is collected live), a try delivers its fall-through
through the inferring cell, which used to snapshot the literal and lose the back
-link. Regression: found by the smith fuzzer.

  $ cat > t.wat <<'WAT'
  > (module
  >   (global $g (mut i32) (i32.const 0))
  >   (func (export "f") (param $p f32) (param $c i32)
  >     block $b (result f32)
  >       try_table $tt (result f32)
  >         local.get $c
  >         if
  >           local.get $p
  >           br $tt
  >         end
  >         f32.const 0x1p-136
  >       end
  >       br $b
  >     end
  >     i32.reinterpret_f32
  >     global.set $g))
  > WAT
  $ wax -i wat -f wax t.wat -o t.wax && wax -i wax -f wasm t.wax -o /dev/null --validate
