The `while` and `try` recoveries (WAT/Wasm to Wax) must not drop or reorder
anything the recovered form cannot express.

A loop label targeted only by a `try_table` catch clause is still targeted, so
the recovered `while` keeps it:

  $ cat > a.wat <<'WAT'
  > (module
  >   (tag $e)
  >   (func $g (param i32))
  >   (func $f (param $c i32)
  >     (loop $L
  >       (if (local.get $c)
  >         (then
  >           (local.set $c (i32.sub (local.get $c) (i32.const 1)))
  >           (try_table (catch_all $L) (call $g (local.get $c)))
  >           (br $L))))))
  > WAT
  $ wax -i wat -f wax a.wat -o a.wax && wax -i wax -f wasm a.wax -o /dev/null --validate

A continue-expression `while 'blk c : (step) { … }` has no spelling for a
branch to the loop itself (one that skips the step), so such a loop keeps its
label and the step stays in the body:

  $ cat > b.wat <<'WAT'
  > (module
  >   (func $f (param $c i32) (param $d i32)
  >     (loop $L
  >       (if (local.get $c)
  >         (then
  >           (block $blk
  >             (br_if $blk (local.get $d))
  >             (br_if $L (local.get $d)))
  >           (local.set $c (i32.sub (local.get $c) (i32.const 1)))
  >           (br $L))))))
  > WAT
  $ wax -i wat -f wax b.wat -o b.wax && wax -i wax -f wasm b.wax -o /dev/null --validate

A `try` arm's payload is picked up by the first value its statement evaluates;
a compound assignment `x += …` reads `x` first, so it is not an arm (the
bracket form remains):

  $ cat > c.wat <<'WAT'
  > (module
  >   (tag $e (param i32))
  >   (func $thrower (param $v i32) (throw $e (local.get $v)))
  >   (func $f (param $v i32) (result i32)
  >     (local $x i32)
  >     (local.set $x (i32.const 100))
  >     (block $join
  >       (local.set $x
  >         (i32.add (local.get $x)
  >           (block $h (result i32)
  >             (try_table (catch $e $h)
  >               (local.set $x (i32.const 1000))
  >               (call $thrower (local.get $v)))
  >             (br $join))))
  >       (br $join))
  >     (local.get $x))
  >   (func (export "main") (result i32) (call $f (i32.const 5))))
  > WAT
  $ wax -i wat -f wax c.wat -o c.wax && wax -i wax -f wasm c.wax -o /dev/null --validate
