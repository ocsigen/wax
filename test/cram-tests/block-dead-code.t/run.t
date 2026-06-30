A block whose value is delivered by a `br` to its own label, with dead code on
an unreachable stack after it, converts (and infers its result) without a
spurious "value remains on the stack":

  $ wax dead.wat -f wax
  #[export = "f"]
  fn f() -> i32 {
      let x: i32;
      x =
          x
              + 'l_2: do {
                    br 'l_2 0x4;
                    (_ as i32).ctz();
                };
      x;
  }

It round-trips, reconstructing the original `(block (result i32) …)`:

  $ wax dead.wat -f wax | wax -i wax -f wat
  (func $f (export "f") (result i32)
    (local $x i32)
    (local.set $x
      (i32.add (local.get $x)
        (block $l_2 (result i32) (br $l_2 (i32.const 0x4)) (i32.ctz))))
    (local.get $x)
  )
