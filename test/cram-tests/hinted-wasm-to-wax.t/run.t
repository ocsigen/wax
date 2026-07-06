Converting Wasm to Wax must look inside branch hints too. A declarative element
segment referenced only by an `elem.drop` (or `table.init`, `array.*_elem`)
nested in a hinted branch was once missed, so the segment was dropped and the
generated Wax referred to an unbound name. The segment is now kept and named:

  $ wax -i wat -f wax m.wat
  fn f() {}
  elem e: &func = [];
  fn f_2(x: i32) {
      #[likely]
      if x {
          e.drop();
      }
  }
