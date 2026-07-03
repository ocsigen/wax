A local used only inside the block that initializes another binding
(`let outer = do { ... }`) sinks into that block rather than staying a bare
declaration before it. Once inside, its first assignment fuses into the `let`,
so `$inner` becomes `let inner = x + 1;` nested in the `do` block:

  $ wax init.wat -f wax
  fn f(x: i32) -> i32 {
      let outer =
          'b: do {
              let inner = x + 1;
              inner * inner;
          };
      outer;
  }
