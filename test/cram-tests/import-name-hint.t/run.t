An anonymous import (no $id, not re-exported) borrows its import name as the Wax
name, mirroring how an entity borrows its export name. A keyword or otherwise
invalid name is skipped in favour of the generated default, with the real name
kept in an #[import] / #[export] attribute.

  $ wax -i wat -f wax names.wat
  import "env" {
      fn malloc(i32) -> i32;
      let counter: i32;
      #[import = "memory"]
      memory m: i32 [1];
      #[import = "some.fn"]
      fn f();
  }
  #[export = "loop"]
  fn f_2() -> i32 {
      0;
  }
