The parenthesized type ascription (e : t): a static assertion that e's type is
a subtype of t, with result type t. It never lowers to an instruction, and —
unlike a cast — an ascribed bare hole claims no pending value: it grounds a
value of type t off the polymorphic floor (the type-independent
generalization of the bottom-cast dead-code pin).

Subsumption and literal pinning; the ascription survives formatting and lowers
to nothing:

  $ cat > ok.wax <<'WAX'
  > type s = { a: i32 };
  > #[export]
  > fn f() -> i64 {
  >     let up: &?any = ({s| a: 1 } : &?any);
  >     _ = up;
  >     let y = (5 : i64);
  >     (y + 2 : i64);
  > }
  > WAX
  $ wax ok.wax
  type s = { a: i32 };
  #[export]
  fn f() -> i64 {
      let up: &?any = ({s| a: 1 } : &?any);
      _ = up;
      let y = (5 : i64);
      (y + 2 : i64);
  }
  $ wax ok.wax -f wat
  (type $s (struct (field $a i32)))
  (func $f (export "f") (result i64)
    (local $up anyref) (local $y i64)
    (local.set $up (struct.new $s (i32.const 1)))
    (drop (local.get $up))
    (local.set $y (i64.const 5))
    (i64.add (local.get $y) (i64.const 2))
  )

An ascription asserts, never converts: a non-subtype operand is rejected (an
i32 is not an i64 — that widening is `as`'s job), and so is a downcast (a
&?any is not necessarily a &s — that runtime test is `as`'s job too):

  $ cat > bad.wax <<'WAX'
  > fn g(x: i32) -> i64 {
  >     (x : i64);
  > }
  > WAX
  $ wax check --error-format short bad.wax
  bad.wax:2:6: error: This expression has type 'i32' but is expected to have type 'i64'.
  [128]

  $ cat > down.wax <<'WAX'
  > type s = { a: i32 };
  > fn h(x: &?any) -> &?s {
  >     (x : &?s);
  > }
  > WAX
  $ wax check --error-format short down.wax
  down.wax:3:6: error: This expression has type '&?any' but is expected to have type '&?s'.
  [128]

An ascribed bare hole claims no pending value, at any type — reference or
numeric — and grounds the context instead (dead code only, like any hole).
The ternary keeps its own colon:

  $ cat > holes.wax <<'WAX'
  > #[export]
  > fn k(a: i32, b: i64, c: i64) -> i64 {
  >     let t = (a != 0 ? b : c);
  >     return (t : i64);
  >     _ = !(_ : &?extern);
  >     _ = (_ : i64) + 1;
  > }
  > WAX
  $ wax holes.wax -f wat
  (func $k (export "k")
    (param $a i32) (param $b i64) (param $c i64) (result i64)
    (local $t i64)
    (local.set $t
      (select (local.get $b) (local.get $c)
        (i32.ne (local.get $a) (i32.const 0))))
    (return (local.get $t))
    (drop (ref.is_null))
    (drop (i64.add (i64.const 1)))
  )
