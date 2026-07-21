A binding annotation (`let x: T = <initializer>`) is dropped on the Wasm->Wax
path only when an unannotated `let x = <initializer>` would re-infer the same
type. The decision reads each construct's *own* re-inference, joined
compositionally (see the `reinfer` machinery in `typing.ml`), rather than a
branch/exit cell that the expected type has already flowed into — so a tail
whose type came from the context no longer looks spuriously redundant.

A flexible integer literal in an `if` re-defaults to i32, so an `i64` binding
annotation is load-bearing and kept; the round-trip is byte-identical.

  $ wax flexible-i64.wat -f wax
  fn f(y: i32) {
      let x: i64 =
          if y {
              1;
          } else {
              2;
          };
  }
  $ wax flexible-i64.wat -f wax | wax -i wax -f wat
  (func $f (param $y i32)
    (local $x i64)
    (local.set $x
      (if (result i64) (local.get $y)
        (then (i64.const 1))
        (else (i64.const 2))))
  )


Flexible arithmetic (`1 + 2`) is inferred over its operands, so no syntactic
pattern at the tail could recognise it — the compositional re-inference does.

  $ wax flexible-arith-i64.wat -f wax
  fn f(y: i32) {
      let x: i64 =
          if y {
              1 + 2;
          } else {
              2;
          };
  }
  $ wax flexible-arith-i64.wat -f wax | wax -i wax -f wat
  (func $f (param $y i32)
    (local $x i64)
    (local.set $x
      (if (result i64) (local.get $y)
        (then (i64.add (i64.const 1) (i64.const 2)))
        (else (i64.const 2))))
  )


A `null` nested one level below the tail re-infers the floating `&?none`; the
nested `if` reports its own join upward, so the outer annotation is kept.

  $ wax nested-null.wat -f wax
  type t = { };
  fn f(y: i32, z: &?t) {
      let x: &?t =
          if y {
              if y {
                  null;
              } else {
                  null;
              }
          } else {
              null;
          };
      x = z;
  }
  $ wax nested-null.wat -f wax | wax -i wax -f wat
  (type $t (struct))
  (func $f (param $y i32) (param $z (ref null $t))
    (local $x (ref null $t))
    (local.set $x
      (if (result (ref null $t)) (local.get $y)
        (then
          (if (result (ref null $t)) (local.get $y)
            (then (ref.null $t))
            (else (ref.null $t))))
        (else (ref.null $t))))
    (local.set $x (local.get $z))
  )


A flexible literal nested one level below the tail, likewise.

  $ wax nested-flexible-i64.wat -f wax
  fn f(y: i32) {
      let x: i64 =
          if y {
              if y {
                  1;
              } else {
                  2;
              }
          } else {
              2;
          };
  }
  $ wax nested-flexible-i64.wat -f wax | wax -i wax -f wat
  (func $f (param $y i32)
    (local $x i64)
    (local.set $x
      (if (result i64) (local.get $y)
        (then
          (if (result i64) (local.get $y)
            (then (i64.const 1))
            (else (i64.const 2))))
        (else (i64.const 2))))
  )


Not blanket-conservative: a flexible literal in one arm joins with a typed `i64`
sibling in the other, so an unannotated `let` would re-infer `i64` and the
annotation drops.

  $ wax mixed-flexible-pinned.wat -f wax
  fn f(y: i32, z: i64) {
      let x =
          if y {
              1;
          } else {
              z;
          };
  }
  $ wax mixed-flexible-pinned.wat -f wax | wax -i wax -f wat
  (func $f (param $y i32) (param $z i64)
    (local $x i64)
    (local.set $x
      (if (result i64) (local.get $y)
        (then (i64.const 1))
        (else (local.get $z))))
  )


An `f32.const` decompiles to a bare integer-looking literal, which re-defaults
to i32 (not f32), so the `f32` binding is load-bearing and kept.

  $ wax flexible-f32.wat -f wax
  fn f(y: i32) {
      let x: f32 =
          if y {
              1;
          } else {
              2;
          };
  }
  $ wax flexible-f32.wat -f wax | wax -i wax -f wat
  (func $f (param $y i32)
    (local $x f32)
    (local.set $x
      (if (result f32) (local.get $y)
        (then (f32.const 1))
        (else (f32.const 2))))
  )


A nested `do` whose tail is an un-named array literal cannot re-infer its element
type, so the block is uninferrable and the outer annotation is kept.

  $ wax do-unnamed-array.wat -f wax
  type t = [i8];
  fn f() {
      let x: &t =
          do {
              [1];
          };
  }
  $ wax do-unnamed-array.wat -f wax | wax -i wax -f wat
  (type $t (array i8))
  (func $f
    (local $x (ref $t))
    (local.set $x
      (block (result (ref $t)) (array.new_fixed $t 1 (i32.const 1))))
  )


When a nested `do`'s own `=> T` result annotation survives (its type differs
from the surrounding context, here `&eq`), the block pins its type through that
written annotation. The outer binding keeps its own annotation only by exact
equality, never by narrowing it down to the block's subtype — narrowing would
flip the decompilation between "outer annotation" and "block result" on the next
round-trip. So the outer `&eq` is kept, and the form is a fixed point.

  $ wax do-kept-annotation.wat -f wax
  type t = [i8];
  fn f() {
      let x: &eq =
          do &t {
              [1];
          };
  }
  $ wax do-kept-annotation.wat -f wax | wax -i wax -f wat
  (type $t (array i8))
  (func $f
    (local $x (ref eq))
    (local.set $x
      (block (result (ref $t)) (array.new_fixed $t 1 (i32.const 1))))
  )


A `select` with one `null` operand and one typed operand joins to the typed
type, so the annotation drops (the same sibling-rescue precision the `if` arm
has); with both operands `null` the join is the floating `&?none` and it is kept.

  $ wax select-one-null.wat -f wax
  type t = { };
  fn f(c: i32, z: &?t) {
      let x = c?null:z;
  }
  $ wax select-both-null.wat -f wax
  type t = { };
  fn f(c: i32, z: &?t) {
      let x: &?t = c?null:null;
      x = z;
  }


A value delivered by a `br` to the if's own label (which `from_wasm` does emit)
reaches the exit but is invisible to the fall-through join. Here the delivered
value is an un-named array that could not re-infer its element type without the
annotation, so the annotation is load-bearing and kept, and the round-trip
survives.

  $ wax br-to-own-label.wat -f wax
  type t = [i8];
  fn f(c: i32, z: &t) {
      let x: &t =
          'l: if c {
              br 'l [1];
          } else {
              z;
          };
  }
  $ wax br-to-own-label.wat -f wax | wax -i wax -f wat
  (type $t (array i8))
  (func $f (param $c i32) (param $z (ref $t))
    (local $x (ref $t))
    (local.set $x
      (if $l (result (ref $t)) (local.get $c)
        (then (br $l (array.new_fixed $t 1 (i32.const 1))))
        (else (local.get $z))))
  )
