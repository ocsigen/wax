A value-producing `do` block in expression position infers its result type from
every value reaching its exit — the fall-through value plus each `br` to its own
label — so the explicit result annotation drops:

  $ wax multi-exit.wat -f wax
  #[export = "f"]
  fn f(c: i32) -> i32 {
      0
          + 'b: do {
                if c {
                    br 'b 5;
                }
                7;
            };
  }

It round-trips: re-converting reproduces the original `(block … (result i32))`,
the type re-inferred from the `br` value and the fall-through:

  $ wax multi-exit.wat -f wax | wax -i wax -f wat
  (func $f (export "f") (param $c i32) (result i32)
    (i32.add (i32.const 0)
      (block $b (result i32)
        (if (local.get $c) (then (br $b (i32.const 5))))
        (i32.const 7)))
  )
