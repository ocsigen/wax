A compound assignment `x op= e` lowers to `local.set $x (op (local.get $x) e)`:
the implicit `local.get $x` is pushed before `e`. So a hole `_` in `e` would
consume the value below that receiver, computing `_ op x` instead of `x op e` --
a silent operand swap for every non-commutative op. The plain form `x = x op _`
is already rejected by the hole-order check ("occurs before a hole"); the
compound form must be rejected the same way rather than miscompiled.

  $ cat > swap.wax <<'WAX'
  > fn f(c: i32) -> i32 {
  >     let x = 100; 7;
  >     if c => (i32) { x -= _; } else { _ = _; }
  >     x;
  > }
  > WAX

  $ wax -i wax -f wat swap.wax
  Error: This expression occurs before a hole '_'.
   ──➤  swap.wax:3:21
  1 │ fn f(c: i32) -> i32 {
  2 │     let x = 100; 7;
  3 │     if c => (i32) { x -= _; } else { _ = _; }
    ·                     ^
  4 │     x;
  5 │ }
  [128]

The plain-binop equivalent is rejected identically:

  $ cat > plain.wax <<'WAX'
  > fn f(c: i32) -> i32 {
  >     let x = 100; 7;
  >     if c => (i32) { x = x - _; } else { _ = _; }
  >     x;
  > }
  > WAX

  $ wax -i wax -f wat plain.wax
  Error: This expression occurs before a hole '_'.
   ──➤  plain.wax:3:25
  1 │ fn f(c: i32) -> i32 {
  2 │     let x = 100; 7;
  3 │     if c => (i32) { x = x - _; } else { _ = _; }
    ·                         ^
  4 │     x;
  5 │ }
  [128]

A compound assignment with no hole in its right-hand side is unaffected:

  $ cat > ok.wax <<'WAX'
  > fn f(x: i32) -> i32 {
  >     x -= 5;
  >     x;
  > }
  > WAX

  $ wax -i wax -f wat ok.wax
  (func $f (param $x i32) (result i32)
    (local.set $x (i32.sub (local.get $x) (i32.const 5)))
    (local.get $x)
  )
