A source-named local wins the plain name over the generated default: even
though the unnamed local at index 0 is registered first, `$x` keeps `x` and the
unnamed one is decompiled as `x_2` (not the reverse):

  $ wax locals.wat -f wax
  #[export = "f"]
  fn f() -> i32 {
      let x_2 = 1;
      let x = 2;
      x_2 + x;
  }

It round-trips (the two locals stay distinct):

  $ wax locals.wat -f wax | wax -i wax -f wat
  (func $f (export "f") (result i32)
    (local $x_2 i32) (local $x i32)
    (local.set $x_2 (i32.const 1))
    (local.set $x (i32.const 2))
    (i32.add (local.get $x_2) (local.get $x))
  )
