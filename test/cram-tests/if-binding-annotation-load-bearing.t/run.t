When a binding's initializer is an `if`, its type annotation is dropped only
when the branches alone re-infer the same type. It must be kept when a branch
bottoms out in a value that cannot re-infer its type without the annotation
flowing in — otherwise the decompiled Wax no longer type-checks or no longer
round-trips.

An un-named array literal in a (nested) branch can name no element type on its
own, so the `let x: &?t` annotation is kept:

  $ wax array.wat -f wax
  type t = [i8];
  fn f(y: i32, z: &?t) {
      let x: &?t =
          if y {
              if y {
                  [1];
              } else {
                  [2];
              }
          } else {
              z;
          };
  }

The kept annotation lets it round-trip back to the original module:

  $ wax array.wat -f wax | wax -i wax -f wat
  (type $t (array i8))
  (func $f (param $y i32) (param $z (ref null $t))
    (local $x (ref null $t))
    (local.set $x
      (if (result (ref null $t)) (local.get $y)
        (then
          (if (result (ref null $t)) (local.get $y)
            (then (array.new_fixed $t 1 (i32.const 1)))
            (else (array.new_fixed $t 1 (i32.const 2)))))
        (else (local.get $z))))
  )

The same holds through a `?:`, which threads the type into both its branches:

  $ wax select.wat -f wax | wax -i wax -f wat
  (type $t (array i8))
  (func $f (param $y i32) (param $z (ref null $t))
    (local $x (ref null $t))
    (local.set $x
      (if (result (ref null $t)) (local.get $y)
        (then
          (select (result (ref null $t)) (array.new_fixed $t 1 (i32.const 1))
            (local.get $z) (local.get $y)))
        (else (local.get $z))))
  )

A bare `null` re-infers the floating `&?none` (it lowers to `ref.null none`), so
when *every* arm is a `null` the annotation is load-bearing and kept:

  $ wax both-null.wat -f wax
  type t = [i8];
  fn f(y: i32) {
      let x: &?t =
          if y {
              null;
          } else {
              null;
          };
  }

  $ wax both-null.wat -f wax | wax -i wax -f wat
  (type $t (array i8))
  (func $f (param $y i32)
    (local $x (ref null $t))
    (local.set $x
      (if (result (ref null $t)) (local.get $y)
        (then (ref.null $t))
        (else (ref.null $t))))
  )

But a lone `null` arm whose sibling pins the concrete type does not need it —
their join is that type — so the annotation still drops:

  $ wax one-null.wat -f wax
  type t = [i8];
  fn f(y: i32, z: &?t) {
      let x =
          if y {
              null;
          } else {
              z;
          };
  }
