Two `br_on_cast_fail` (or more) to the same block, when the end of that block is
unreachable (here a `return`; `unreachable` or a `br` behave the same way):
converting the module to wax fails on the second branch with "The label 'l' is
not bound", although the label is in scope for the whole block and binaryen
accepts the module. A single `br_on_cast_fail`, a block that ends with a value,
or two `br_if` to the same label all convert fine. Found in the wasm_of_ocaml
runtime (`$same_object` in runtime/wasm/marshal.wat), where `tools/wat2wax.sh`
rejected it.

The module must convert, and the result must round-trip to a valid module:

  $ cat > a.wat <<'WAT'
  > (module
  >   (type $s (struct (field i32)))
  >   (func $f (param $a (ref eq)) (param $b (ref eq)) (result i32)
  >     (local $x (ref $s)) (local $y (ref $s))
  >     (drop (block $l (result (ref eq))
  >       (local.set $x (br_on_cast_fail $l (ref eq) (ref $s) (local.get $a)))
  >       (local.set $y (br_on_cast_fail $l (ref eq) (ref $s) (local.get $b)))
  >       (return (i32.const 1))))
  >     (i32.const 0)))
  > WAT
  $ wax -i wat -f wax a.wat -o a.wax && wax -i wax -f wasm a.wax -o /dev/null --validate
  Warning [unused-local]: The local variable 'x' is never used.
   ──➤  a.wax:5:17
  3 │     _ =
  4 │         'l: do {
  5 │             let x = br_on_cast_fail 'l &s a;
    ·                 ^
  6 │             let y = br_on_cast_fail 'l &s b;
  7 │             return 1;
  Warning [unused-local]: The local variable 'y' is never used.
   ──➤  a.wax:6:17
  4 │         'l: do {
  5 │             let x = br_on_cast_fail 'l &s a;
  6 │             let y = br_on_cast_fail 'l &s b;
    ·                 ^
  7 │             return 1;
  8 │         };

The nested type-test ladder has the same hole: an arm body that still branches
to a ladder label (here arm `$L0`'s body to the next arm's block `$L1`) must
keep the ladder rather than fold into a `match` that no longer binds the label:

  $ cat > b.wat <<'WAT'
  > (module
  >   (type $s (struct (field i32)))
  >   (type $t (struct (field f32)))
  >   (func $f (param $a anyref) (param $c i32) (param $u (ref $t)) (result i32)
  >     (block $esc
  >       (block $L1 (result (ref $t))
  >         (block $L0 (result (ref $s))
  >           (drop (br_on_cast $L1 anyref (ref $t) (br_on_cast $L0 anyref (ref $s) (local.get $a))))
  >           (br $esc))
  >         (drop)
  >         (drop (br_if $L1 (local.get $u) (local.get $c)))
  >         (return (i32.const 1)))
  >       (drop)
  >       (return (i32.const 2)))
  >     (i32.const 0)))
  > WAT
  $ wax -i wat -f wax b.wat -o b.wax && wax -i wax -f wasm b.wax -o /dev/null --validate

The same folds used to drop the declaration of a local that an arm rebinds as
its pattern variable, even when the local is still used elsewhere: in a later
flat-chain block that writes it too, or in another arm of a nested ladder.

  $ cat > c.wat <<'WAT'
  > (module
  >   (type $s (struct (field i32)))
  >   (func $f (param $a (ref eq)) (param $b (ref eq)) (result i32)
  >     (local $x (ref $s))
  >     (drop (block $l1 (result (ref eq))
  >       (local.set $x (br_on_cast_fail $l1 (ref eq) (ref $s) (local.get $a)))
  >       (return (i32.const 1))))
  >     (drop (block $l2 (result (ref eq))
  >       (local.set $x (br_on_cast_fail $l2 (ref eq) (ref $s) (local.get $a)))
  >       (return (i32.const 2))))
  >     (i32.const 0)))
  > WAT
  $ wax -i wat -f wax c.wat -o c.wax && wax -i wax -f wasm c.wax -o /dev/null --validate
  Warning [unused-local]: The local variable 'x' is never used.
   ──➤  c.wax:3:9
  1 │ type s = { f: i32 };
  2 │ fn f(a: &eq, b: &eq) -> i32 {
  3 │     let x: &s;
    ·         ^
  4 │     _ =
  5 │         'l1: do {
  $ cat > d.wat <<'WAT'
  > (module
  >   (type $s (struct (field i32)))
  >   (type $t (struct (field f32)))
  >   (func $f (param $a anyref) (result i32)
  >     (local $x (ref null $s))
  >     (block $esc
  >       (block $L1 (result (ref $t))
  >         (block $L0 (result (ref $s))
  >           (drop (br_on_cast $L1 anyref (ref $t) (br_on_cast $L0 anyref (ref $s) (local.get $a))))
  >           (br $esc))
  >         (local.set $x)
  >         (return (struct.get $s 0 (local.get $x))))
  >       (drop)
  >       (return (struct.get $s 0 (local.get $x))))
  >     (i32.const 0)))
  > WAT
  $ wax -i wat -f wax d.wat -o d.wax && wax -i wax -f wasm d.wax -o /dev/null --validate

`flat.wax` is a flat `br_on_cast_fail` chain. Besides pinning its round trip
here, it seeds fuzz/recover-shapes.sh, whose line-duplicating mutations of its
lowered form reach the shapes above; the `.wax` fixtures are otherwise all
nested ladders.

  $ wax flat.wax -f wat -o flat.wat && wax -i wat -f wax flat.wat
  type s = { f: i32 };
  type t = { g: f32 };
  fn f(a: &eq) -> i32 {
      match a {
          x: &s => {
              return x.f;
          }
          y: &t => {
              return 2;
          }
          _ => {
              0;
          }
      }
  }

A second branch to a folded label may also sit in the scrutinee, which moves
out of the blocks too: nested into the flat chain's test, or run before the
ladder's type tests.

  $ cat > e.wat <<'WAT'
  > (module
  >   (type $s (struct (field i32)))
  >   (func $f (param $a (ref eq)) (result i32)
  >     (local $x (ref $s))
  >     (drop (block $l (result (ref eq))
  >       (local.set $x (br_on_cast_fail $l (ref eq) (ref $s) (br_on_cast_fail $l (ref eq) (ref $s) (local.get $a))))
  >       (return (i32.const 1))))
  >     (i32.const 0)))
  > WAT
  $ wax -i wat -f wax e.wat -o e.wax && wax -i wax -f wasm e.wax -o /dev/null --validate
  Warning [unused-local]: The local variable 'x' is never used.
   ──➤  e.wax:5:17
  3 │     _ =
  4 │         'l: do {
  5 │             let x = br_on_cast_fail 'l &s br_on_cast_fail 'l &s a;
    ·                 ^
  6 │             return 1;
  7 │         };
  $ cat > f.wat <<'WAT'
  > (module
  >   (type $s (struct (field i32)))
  >   (type $t (struct (field f32)))
  >   (func $f (param $a anyref) (param $c i32) (result i32)
  >     (block $esc
  >       (block $L1 (result (ref $t))
  >         (block $L0 (result (ref $s))
  >           (drop (br_on_cast $L1 anyref (ref $t) (br_on_cast $L0 anyref (ref $s)
  >              (block (result anyref) (br_if $L1 (struct.new $t (f32.const 0)) (local.get $c)) (drop) (local.get $a)))))
  >           (br $esc))
  >         (drop)
  >         (return (i32.const 1)))
  >       (drop)
  >       (return (i32.const 2)))
  >     (i32.const 0)))
  > WAT
  $ wax -i wat -f wax f.wat -o f.wax && wax -i wax -f wasm f.wax -o /dev/null --validate

A fold must not turn a write to a local that is read outside the arm into the
arm's binding: the arm leaves by a loop back-edge, and the next iteration's
default reads the value it wrote. Folding compiled to a fresh local, so the
read saw null instead (`main` returned 0, not 1). Both the flat chain and the
nested ladder keep the write to the shared `x`:

  $ cat > g.wat <<'WAT'
  > (module
  >   (type $s (struct (field i32)))
  >   (func $f (export "f") (param $a eqref) (result i32)
  >     (local $x (ref null $s))
  >     (loop $L
  >       (drop (block $l (result eqref)
  >         (local.set $x (br_on_cast_fail $l eqref (ref $s) (local.get $a)))
  >         (local.set $a (ref.i31 (i32.const 7)))
  >         (br $L)))
  >       (return (if (result i32) (ref.is_null (local.get $x)) (then (i32.const 0)) (else (i32.const 1)))))
  >     (unreachable))
  >   (func (export "main") (result i32)
  >     (call $f (struct.new $s (i32.const 3)))))
  > WAT
  $ wax -i wat -f wax g.wat
  type s = { f: i32 };
  #[export]
  fn f(a: &?eq) -> i32 {
      'L: loop {
          let x: &?s;
          _ =
              'l: do {
                  x = br_on_cast_fail 'l &s a;
                  a = 7 as &i31;
                  br 'L;
              };
          return
              if !x {
                  0;
              } else {
                  1;
              };
      }
      unreachable;
  }
  #[export]
  fn main() -> i32 {
      f({ f: 3 });
  }
  $ cat > h.wat <<'WAT'
  > (module
  >   (type $s (struct (field i32)))
  >   (type $t (struct (field f32)))
  >   (func $f (export "f") (param $a anyref) (result i32)
  >     (local $x (ref null $s))
  >     (loop $L
  >       (block $esc
  >         (block $L1 (result (ref $t))
  >           (block $L0 (result (ref $s))
  >             (drop (br_on_cast $L1 anyref (ref $t) (br_on_cast $L0 anyref (ref $s) (local.get $a))))
  >             (br $esc))
  >           (local.set $x)
  >           (local.set $a (ref.i31 (i32.const 7)))
  >           (br $L))
  >         (drop)
  >         (return (i32.const 2)))
  >       (return (if (result i32) (ref.is_null (local.get $x)) (then (i32.const 0)) (else (i32.const 1)))))
  >     (unreachable))
  >   (func (export "main") (result i32)
  >     (call $f (struct.new $s (i32.const 3)))))
  > WAT
  $ wax -i wat -f wax h.wat
  type s = { f: i32 };
  type t = { f: f32 };
  #[export]
  fn f(a: &?any) -> i32 {
      'L: loop {
          let x: &?s;
          'esc: do {
              _ =
                  'L1: do {
                      x =
                          'L0: do &s {
                              _ = br_on_cast 'L1 &t br_on_cast 'L0 &s a;
                              br 'esc;
                          };
                      a = 7 as &i31;
                      br 'L;
                  };
              return 2;
          }
          return
              if !x {
                  0;
              } else {
                  1;
              };
      }
      unreachable;
  }
  #[export]
  fn main() -> i32 {
      f({s| f: 3 });
  }
