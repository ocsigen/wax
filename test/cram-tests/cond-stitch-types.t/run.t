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
