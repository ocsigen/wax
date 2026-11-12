A type declared in both branches of a top-level conditional has a different
definition in each. The lowering must resolve each branch's names against that
branch's own definitions: here `ext` splices its supertype `base`, whose field
`a` is an i32 in one branch and an i64 in the other. Each specialization
compiles on its own, and so must the module with the conditional preserved --
the then-branch's `ext` must not pick up the else-branch's `base`.

  $ wax -f wat -D A splice.wax
  (type $base (sub (struct (field $a i32))))
  (type $ext (sub final $base (struct (field $a i32) (field $b i32))))
  (func $mk (result (ref $ext)) (struct.new $ext (i32.const 1) (i32.const 2)))
  $ wax -f wat -D A=false splice.wax
  (type $base (sub (struct (field $a i64))))
  (type $ext (sub final $base (struct (field $a i64) (field $b i32))))
  (func $mk (result (ref $ext)) (struct.new $ext (i64.const 1) (i32.const 2)))
  $ wax -f wat splice.wax
  (@if $A
    (@then
      (type $base (sub (struct (field $a i32))))
      (type $ext (sub final $base (struct (field $a i32) (field $b i32))))
      (func $mk (result (ref $ext))
        (struct.new $ext (i32.const 1) (i32.const 2))))
    (@else
      (type $base (sub (struct (field $a i64))))
      (type $ext (sub final $base (struct (field $a i64) (field $b i32))))
      (func $mk (result (ref $ext))
        (struct.new $ext (i64.const 1) (i32.const 2))))
  )

A statement-level conditional inside a body is typed the same way, each branch
in the world where it exists, so a name each branch declares for itself resolves
to that branch's own definition, here `h` with a different result type per
branch:

  $ cat > names.wax <<'WAX'
  > #[if(A)]
  > {
  >     fn h() -> i32 { 1 }
  > }
  > #[else]
  > {
  >     fn h() -> i64 { 2 }
  > }
  > fn k() -> i32 {
  >     #[if(A)]
  >     {
  >         h()
  >     }
  >     #[else]
  >     {
  >         h() as i32
  >     }
  > }
  > WAX
  $ wax -f wat names.wax
  (@if $A
    (@then (func $h (result i32) (i32.const 1)))
    (@else (func $h (result i64) (i64.const 2)))
  )
  (func $k (result i32)
    (@if $A (@then (call $h)) (@else (i32.wrap_i64 (call $h))))
  )

A conditional without an else-branch still has a world where its then-branch is
absent, and a later branch may exist only there: here the import exists only
under `c`, and the else-branches of `a` and `g` only under `not c`. Each must be
typed in that world, so `g`'s else-branch reads `a`'s i32 elements, in both
directions:

  $ cat > else-less.wat <<'WAT'
  > (module
  >   (@if $c (@then (import "m" "h" (func $h (param f64) (result f32)))))
  >   (@if $c
  >     (@then (type $a (array (mut i64))))
  >     (@else (type $a (array (mut i32)))))
  >   (@if $c
  >     (@then
  >       (func $g (export "g") (param $d (ref $a)) (result i32)
  >         (drop (call $h (f64.const 0)))
  >         (i32.wrap_i64 (array.get $a (local.get $d) (i32.const 0)))))
  >     (@else
  >       (func $g (export "g") (param $d (ref $a)) (result i32)
  >         (i32.ne (array.get $a (local.get $d) (i32.const 0)) (i32.const 0))))))
  > WAT
  $ wax -f wax else-less.wat -o else-less.wax
  $ cat else-less.wax
  #[if(c)]
  {
      import "m" fn h(f64) -> f32;
  }
  #[if(c)]
  {
      type a = [mut i64];
  }
  #[else]
  {
      type a = [mut i32];
  }
  #[if(c)]
  {
      #[export]
      fn g(d: &a) -> i32 {
          _ = h(0);
          d[0] as i32;
      }
  }
  #[else]
  {
      #[export]
      fn g(d: &a) -> i32 {
          d[0] != 0;
      }
  }
  $ wax -f wat else-less.wax
  (@if $c (@then (import "m" "h" (func $h (param f64) (result f32)))))
  (@if $c
    (@then (type $a (array (mut i64))))
    (@else (type $a (array (mut i32))))
  )
  (@if $c
    (@then
      (func $g (export "g") (param $d (ref $a)) (result i32)
        (drop (call $h (f64.const 0)))
        (i32.wrap_i64 (array.get $a (local.get $d) (i32.const 0)))))
    (@else
      (func $g (export "g") (param $d (ref $a)) (result i32)
        (i32.ne (array.get $a (local.get $d) (i32.const 0)) (i32.const 0))))
  )

More generally, a branch is typed in a world its own condition and the enclosing
ones describe, whatever was decided at the conditionals before it: `g`'s
then-branch exists only when neither `a` nor `b` holds, so it reads `t`'s i32
elements:

  $ cat > path.wat <<'WAT'
  > (module
  >   (@if $a
  >     (@then (type $t (array (mut i64))))
  >     (@else (type $t (array (mut i32)))))
  >   (@if $b
  >     (@then (global $x i32 (i32.const 0)))
  >     (@else (global $x i32 (i32.const 1))))
  >   (@if (and (not $a) (not $b))
  >     (@then
  >       (func $g (export "g") (param $d (ref $t)) (result i32)
  >         (i32.ne (array.get $t (local.get $d) (i32.const 0)) (i32.const 0))))
  >     (@else
  >       (func $g (export "g") (param $d (ref $t)) (result i32)
  >         (i32.const 0)))))
  > WAT
  $ wax -f wax path.wat -o path.wax
  $ cat path.wax
  #[if(a)]
  {
      type t = [mut i64];
  }
  #[else]
  {
      type t = [mut i32];
  }
  #[if(b)]
  {
      const x = 0;
  }
  #[else]
  {
      const x = 1;
  }
  #[if(all(not(a), not(b)))]
  {
      #[export]
      fn g(d: &t) -> i32 {
          d[0] != 0;
      }
  }
  #[else]
  {
      #[export]
      fn g(d: &t) -> i32 {
          0;
      }
  }
  $ wax -f wat path.wax
  (@if $a
    (@then (type $t (array (mut i64))))
    (@else (type $t (array (mut i32))))
  )
  (@if $b
    (@then (global $x i32 (i32.const 0)))
    (@else (global $x i32 (i32.const 1)))
  )
  (@if (and (not $a) (not $b))
    (@then
      (func $g (export "g") (param $d (ref $t)) (result i32)
        (i32.ne (array.get $t (local.get $d) (i32.const 0)) (i32.const 0))))
    (@else
      (func $g (export "g") (param $d (ref $t)) (result i32) (i32.const 0)))
  )
