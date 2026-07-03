A `while` may carry a Zig-style continue-expression, `while c : (step) { … }`.
The step is a statement run at the end of every iteration. Without a `continue`
(a branch to the loop label) it simply lowers after the body:

  $ wax -f wat - <<'WAX'
  > fn sum(n: i32) -> i32 {
  >   let i: i32 = 0;
  >   let total: i32 = 0;
  >   while i <s n : (i += 1) { total += i; }
  >   total;
  > }
  > WAX
  (func $sum (param $n i32) (result i32)
    (local $i i32) (local $total i32)
    (local.set $i (i32.const 0))
    (local.set $total (i32.const 0))
    (loop $loop
      (if (i32.lt_s (local.get $i) (local.get $n))
        (then
          (local.set $total (i32.add (local.get $total) (local.get $i)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $loop))))
    (local.get $total)
  )

With a `continue`, the step must still run before re-testing. A labelled loop
wraps the body in a block (the continue target) so a branch to the label runs
the step and then takes the back-edge — the fix for the "continue gap":

  $ wax -f wat - <<'WAX'
  > fn f(n: i32) -> i32 {
  >   let i: i32 = 0;
  >   let total: i32 = 0;
  >   'l: while i <s n : (i += 1) {
  >     if (i %s 2) == 0 { br 'l; }
  >     total += i;
  >   }
  >   total;
  > }
  > WAX
  (func $f (param $n i32) (result i32)
    (local $i i32) (local $total i32)
    (local.set $i (i32.const 0))
    (local.set $total (i32.const 0))
    (loop $loop
      (if (i32.lt_s (local.get $i) (local.get $n))
        (then
          (block $l
            (if (i32.eq (i32.rem_s (local.get $i) (i32.const 2)) (i32.const 0))
              (then (br $l)))
            (local.set $total (i32.add (local.get $total) (local.get $i))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $loop))))
    (local.get $total)
  )

The continue-expression is preserved when reformatting Wax:

  $ wax -f wax - <<'WAX'
  > fn f(n: i32) -> i32 {
  >   let i: i32 = 0;
  >   'l: while i <s n : (i += 1) { if i == 0 { br 'l; } }
  >   i;
  > }
  > WAX
  fn f(n: i32) -> i32 {
      let i: i32 = 0;
      'l: while i <s n : (i += 1) {
          if i == 0 {
              br 'l;
          }
      }
      i;
  }

Decompiling the distinctive shape (a labelled block that branches to itself,
followed by the step, before the back-edge) recovers the continue-expression:

  $ wax -i wat -f wax - <<'WAT'
  > (module (func $f (param $n i32) (result i32) (local $i i32) (local $t i32)
  >   (loop $loop
  >     (if (i32.lt_s (local.get $i) (local.get $n))
  >       (then
  >         (block $l
  >           (br_if $l (i32.eqz (local.get $i)))
  >           (local.set $t (i32.add (local.get $t) (local.get $i))))
  >         (local.set $i (i32.add (local.get $i) (i32.const 1)))
  >         (br $loop))))
  >   (local.get $t)))
  > WAT
  fn f(n: i32) -> i32 {
      let i: i32;
      let t: i32;
      'l_3: while i <s n : (i += 1) {
          br_if 'l_3 !i;
          t += i;
      }
      t;
  }

Even without a `continue`, a trailing update of a variable the condition reads
(an induction variable) is recovered as a continue-expression, so plain
index-and-stride loops read as `for`-like loops. This is round-trip-safe: it
lowers back to the same Wasm.

  $ wax -i wat -f wax - <<'WAT'
  > (module (func $f (param $n i32) (result i32) (local $i i32) (local $t i32)
  >   (loop $loop
  >     (if (i32.lt_s (local.get $i) (local.get $n))
  >       (then
  >         (local.set $t (i32.add (local.get $t) (local.get $i)))
  >         (local.set $i (i32.add (local.get $i) (i32.const 1)))
  >         (br $loop))))
  >   (local.get $t)))
  > WAT
  fn f(n: i32) -> i32 {
      let i: i32;
      let t: i32;
      while i <s n : (i += 1) {
          t += i;
      }
      t;
  }
