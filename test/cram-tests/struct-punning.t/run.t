A struct-literal field written as a bare name is *punned*: `{x}` is shorthand for
`{x: x}`, taking the value from the like-named local or global. Punned and
explicit fields mix in any order, and the value lowers exactly as the equivalent
`Get` would:

  $ wax -f wat - <<'WAX'
  > type point = { x: i32, y: i32 };
  > fn mk(x: i32, y: i32) -> &point { {point| x, y: y + 1}; }
  > fn copy(x: i32, y: i32) -> &point { {point| x, y}; }
  > WAX
  (type $point (struct (field $x i32) (field $y i32)))
  (func $mk (param $x i32) (param $y i32) (result (ref $point))
    (struct.new $point (local.get $x) (i32.add (local.get $y) (i32.const 1)))
  )
  (func $copy (param $x i32) (param $y i32) (result (ref $point))
    (struct.new $point (local.get $x) (local.get $y))
  )

Reformatting Wax preserves the distinction: a punned field stays punned and an
explicit `x: x` stays explicit (the author's choice is kept).

  $ wax -f wax - <<'WAX'
  > type point = { x: i32, y: i32 };
  > fn mk(x: i32, y: i32) -> &point { {point| x, y: y}; }
  > fn expl(x: i32, y: i32) -> &point { {point| x: x, y: y}; }
  > WAX
  type point = { x: i32, y: i32 };
  fn mk(x: i32, y: i32) -> &point {
      {point| x, y: y };
  }
  fn expl(x: i32, y: i32) -> &point {
      {point| x: x, y: y };
  }

Decompiling introduces the shorthand: a `struct.new` argument that is a plain
`local.get`/`global.get` of the like-named field becomes a punned field, while an
argument that differs (here `y` fed from a different local) stays explicit.

  $ wax -i wat -f wax - <<'WAT'
  > (module
  >   (type $point (struct (field $x i32) (field $y i32)))
  >   (func $f (param $x i32) (param $other i32) (result (ref $point))
  >     (struct.new $point (local.get $x) (local.get $other))))
  > WAT
  type point = { x: i32, y: i32 };
  fn f(x: i32, other: i32) -> &point {
      { x, y: other };
  }

A pun to a name that is not in scope is rejected like any other unbound
reference:

  $ cat > bad.wax <<'WAX'
  > type point = { x: i32, y: i32 };
  > fn f(x: i32) -> &point { {point| x, y}; }
  > WAX
  $ wax check bad.wax
  Error: The variable 'y' is not bound.
   ──➤  bad.wax:2:37
  1 │ type point = { x: i32, y: i32 };
  2 │ fn f(x: i32) -> &point { {point| x, y}; }
    ·                                     ^
  3 │ 
  [128]
