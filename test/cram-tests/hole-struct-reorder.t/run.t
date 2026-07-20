A struct literal written with its fields out of declared order still pairs each
hole with the right pending value: emission (and slicing) follows the declared
field order, so [x] takes the first pending value (i32) and [y] the second (f64)
even though the source writes [y] before [x].

  $ cat > reorder.wax <<'WAX'
  > type S = { x: i32, y: f64 };
  > fn f() -> &S { 1; 2.0; let s = {S| y: _, x: _}; s; }
  > WAX

  $ wax reorder.wax -f wat
  (type $S (struct (field $x i32) (field $y f64)))
  (func $f (result (ref $S))
    (local $s (ref $S))
    (i32.const 1)
    (f64.const 2.0)
    (local.set $s (struct.new $S))
    (local.get $s)
  )

Swapping the pending values so their types no longer match the fields is a clean
type error, not a miscompile:

  $ cat > mismatch.wax <<'WAX'
  > type S = { x: i32, y: f64 };
  > fn f() -> &S { 2.0; 1; let s = {S| y: _, x: _}; s; }
  > WAX

  $ wax mismatch.wax -f wat
  Error: This expression has type 'float' but is expected to have type 'i32'.
   ──➤  mismatch.wax:2:45
  1 │ type S = { x: i32, y: f64 };
  2 │ fn f() -> &S { 2.0; 1; let s = {S| y: _, x: _}; s; }
    ·                                             ^
  3 │ 
  [128]
