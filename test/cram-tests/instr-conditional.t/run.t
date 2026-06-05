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

Converting Wax conditionals to WAT is not yet supported.

  $ wax cond.wax -o out.wat
  wax: internal error, uncaught exception:
       Failure("Wax conditional annotations are not yet supported when converting to WAT.")
       
  [125]
