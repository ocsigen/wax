A bare `;` is an empty statement: it does nothing and is dropped. This makes a
redundant `;` harmless anywhere — most usefully after a block-shaped statement
(`do`/`if`/`while`/`loop`/`dispatch`/`match`/`try`), which needs none (its `}`
ends it) but where the `;`-per-line reflex is strong. Function `f` puts a `;`
after every block; function `g` has leading, doubled, and lone `;` — all
type-check:

  $ wax check stmts.wax

Empty statements carry nothing, so formatting drops them (the canonical form has
none) — this is purely an input tolerance and does not round-trip:

  $ wax convert -f wax stmts.wax
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
  
  #[export = "g"]
  fn g() -> i32 {
      let x = 1;
      x;
  }

The same empty `;` is accepted in the other element lists: module fields (top
level and inside a group `{…}`), import items, and the arm lists of `dispatch`,
`match`, and a legacy `try`/`catch`. It is dropped there too:

  $ wax convert -f wax fields.wax
  import "env" {
      fn ext(i32) -> i32;
      let g: i32;
  }
  
  const c: i32 = 1;
  
  fn grouped() -> i32 {
      c;
  }
  
  #[export = "arms"]
  fn arms(x: i32, r: &any) -> i32 {
      dispatch x [ 'a else 'b ] {
          'a: {
              return 1;
          }
          'b: {
              return 2;
          }
      }
      match r {
          &any => {
              return 0;
          }
          null => {
              return 1;
          }
          _ => {
              return 2;
          }
      }
      'l: try {
          nop;
      } catch {
          _ => {
              nop;
          }
      }
      ext(x);
  }
