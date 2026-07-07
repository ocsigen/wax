A block-shaped statement (`do`/`if`/`while`/`loop`/`dispatch`/`match`/`try`)
needs no trailing `;` — its closing `}` ends the statement. But the `;`-per-line
reflex is strong, so a redundant `;` after one is accepted and simply ignored:
this file, which puts a `;` after every block, type-checks.

  $ wax check blocks.wax

Reformatting drops the redundant `;` (the canonical form has none), so it is
purely an input tolerance and does not round-trip into the output:

  $ wax convert -f wax blocks.wax
  #[export = "f"]
  fn f(c: i32, r: &any) -> i32 {
      do {
          nop;
      }
      if c {
          nop;
      } else {
          nop;
      }
      'l: loop {
          br 'l;
      }
      let i = 0;
      while i <u c : (i += 1) {
          nop;
      }
      dispatch c [ 'a 'b else 'd ] {
          'a: {}
          'b: {}
          'd: {}
      }
      match r {
          _ => {}
      }
      0;
  }
