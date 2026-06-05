Instruction-level conditional annotations inside function bodies.

WAT→Wax: an instruction-level `(@if …)` becomes a Wax `#[if]`/`#[else]` gating
statements.

  $ wax fromwat.wat -o fromwat.wax && cat fromwat.wax
  fn f() -> i32 {
      #[if(debug)]
      {
          log();
          1;
      }
      #[else]
      {
          2;
      }
  }
  fn log() {}

A Wax function using `#[if]`/`#[else]` (with nested all/not conditions)
round-trips to itself.

  $ wax cond.wax -o out.wax && cat out.wax
  fn f() -> i32 {
      let x: i32;
      #[if(all(debug, not(target = "wasm32")))]
      {
          x = 1;
      }
      #[else]
      {
          x = 2;
      }
      x;
  }
  $ wax out.wax -o out2.wax && diff out.wax out2.wax

Type-checking explores configurations: a local assigned in both branches is
accepted (the branches are mutually exclusive).

  $ wax --validate cond.wax -o checked.wax

Conversion to WAT produces an instruction-level `(@if …)`.

  $ wax cond.wax -o out.wat && cat out.wat
  (func $f (result i32)
    (local $x i32)
    (@if (and $debug (not (= $target "wasm32")))
    (@then (local.set $x (i32.const 1)) ) (@else (local.set $x (i32.const 2)) )
    )
    (local.get $x)
  )

A `let` binding inside a conditional branch is rejected (it would leak past the
mutually-exclusive branches); declare the local before the conditional instead.

  $ wax --validate letbad.wax -o checked.wax
  Error:
    A let binding is not allowed inside a conditional annotation; declare the local before the conditional.
   ──➤  letbad.wax:2:20
  1 │ fn f() {
  2 │     #[if(debug)] { let x: i32 = 1; }
    ·                    ^^^^^^^^^^^^^^
  3 │ }
  4 │ 
  [128]

An instruction-level conditional can reference a name imported only in the
matching module-level branch: here `g` exists only when `wasi`, and is called
only from the `wasi` branch. Each branch is type-checked under its own
assumption, so this is accepted and converts with the call preserved.

  $ wax --validate crossref.wax -o checked_crossref.wax
  $ wax crossref.wax -o crossref.wat && cat crossref.wat
  (@if $wasi (@then (import "m" "g" (func $g (result i32))) ) )
  (func $h (result i32)
    (local $x i32)
    (@if $wasi (@then (local.set $x (call $g)) )
    (@else (local.set $x (i32.const 0)) ) )
    (local.get $x)
  )

The conversion composes both ways: round-tripping the Wax through WAT and back
reproduces the same Wax.

  $ wax fromwat.wax -o rt.wat && wax rt.wat -o rt.wax && diff fromwat.wax rt.wax
