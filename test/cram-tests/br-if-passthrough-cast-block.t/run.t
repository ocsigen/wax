Regression (differential-validation fuzzer, reduced): an inferred block's result
annotation must survive `simplify` when a `br_if` pass-through into it is cast.

A `br_if`/`br_on_null` fall-through value continues on the stack typed as the
target block's result; casting it — `(br_if 'l …) as f32` — pins that width. Here
the block is `f64` (its `.to_bits()` feeds an `i64` xor), reached by an
unconditional `br 'l` and, in the dead code after it, a `br_if 'l` whose
pass-through is demoted to f32. `simplify` dropped the `=> f64` annotation because
the join of the delivered values looked like f64; but on re-parse the `as f32`
pins the delivered value's own cell to f32 (with the annotation gone the
pass-through *is* that cell), so the block re-inferred as f32 and `.to_bits()`
yielded i32 where i64 was expected. Delivering a *flexible* numeric value to an
inferring block now marks its annotation needed (only a flexible literal is
pinnable this way — a concrete value is demoted, not re-typed), so it is kept
regardless of what pins the pass-through downstream, and the module round-trips:

  $ cat > f.wat <<'WAT'
  > (module
  >   (global $g (mut i64) (i64.const 0))
  >   (func (export "f") (param $c i32) (result i64)
  >     (i64.xor
  >       (i64.reinterpret_f64
  >         (block $l (result f64)
  >           (br $l (f64.const 1.5))
  >           (drop (f32.demote_f64 (br_if $l (f64.const 2.5) (local.get $c))))
  >           (f64.const 0)))
  >       (global.get $g))))
  > WAT
  $ wax -i wat -f wax f.wat
  let g: i64 = 0;
  #[export = "f"]
  fn f(c: i32) -> i64 {
      ('l_2: do f64 {
           br 'l_2 1.5;
           _ = (br_if 'l_2 (2.5, c)) as f32;
           0;
       }.to_bits() ^ g);
  }
  $ wax -i wat -f wax f.wat -o f.wax && wax -i wax -f wasm f.wax -o /dev/null --validate

The pin need not be the immediate cast: a `select` (ternary) — or any other
consumer — between the `br_if` and the cast pins the pass-through just the same.
Marking `needed` at the delivery site (not the cast site) catches it too:

  $ cat > s.wat <<'WAT'
  > (module
  >   (global $g (mut i64) (i64.const 0))
  >   (func (export "f") (param $c i32) (result i64)
  >     (i64.xor
  >       (i64.reinterpret_f64
  >         (block $l (result f64)
  >           (br $l (f64.const 1.5))
  >           (drop (f32.demote_f64
  >             (select (result f64)
  >               (br_if $l (f64.const 2.5) (local.get $c))
  >               (f64.const 3.5)
  >               (local.get $c))))
  >           (f64.const 0)))
  >       (global.get $g))))
  > WAT
  $ wax -i wat -f wax s.wat -o s.wax && wax -i wax -f wasm s.wax -o /dev/null --validate
