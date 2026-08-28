Regression (fuzz/recover-shapes.sh, a nop-insertion near-miss of the lowered
match ladder): `Recover_match`'s ladder walk read any bare block level as a
NULL arm, which consumes nothing — without checking that the block is VOID. A
`nop` between an arm block's `end` and the `local.set` that binds its result
separates the binding from the block, the walk folded the result-carrying
block as a null arm, the binding's value vanished from the rebuilt `match`,
and the emitted Wax no longer type-checked, on a module the validator accepts.
The recovery must decline instead: unrecovered, the trailing binding's hole
reconnects to the block's value through the statement and the round trip is
exact.

  $ cat > nearmiss.wat <<'WAT'
  > (module
  >   (type $pair (struct (field $a i32) (field $b i32)))
  >   (type $ints (array (mut i32)))
  >   (func $classify (param $v eqref) (result i32)
  >     (local $a (ref $ints)) (local $p (ref $pair))
  >     block $default
  >       block $arm_2
  >         block $arm_1 (result (ref $ints))
  >           block $arm (result (ref $pair))
  >             local.get $v
  >             br_on_cast $arm eqref (ref $pair)
  >             br_on_cast $arm_1 eqref (ref $ints)
  >             br_on_null $arm_2
  >             drop
  >             br $default
  >           end
  >           nop
  >           local.set $p
  >           local.get $p
  >           struct.get $pair $b
  >           return
  >         end
  >         local.set $a
  >         local.get $a
  >         array.len
  >         return
  >       end
  >       i32.const -1
  >       return
  >     end
  >     i32.const 0))
  > WAT
  $ wax check nearmiss.wat && wax -i wat -f wax nearmiss.wat -o nearmiss.wax && echo converted
  converted
  $ wax nearmiss.wax -f wat >/dev/null && echo recompiles
  recompiles

The intact ladder (no interposed nop) still recovers as a match:

  $ sed '/^ *nop$/d' nearmiss.wat > intact.wat
  $ wax -i wat -f wax intact.wat | grep -c 'match v'
  1
