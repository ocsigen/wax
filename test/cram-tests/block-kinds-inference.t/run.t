Result-type inference (and dropping the redundant annotation, recovered from the
checking context on re-parse) applies to every value-producing block form, not
just `if` and `do`. A `loop` takes its result from the function's return type:

  $ wax loop.wat -f wax
  #[export = "f"]
  fn f(n: i32) -> i32 {
      'l_2: loop {
          br_if 'l_2 n;
          9;
      }
  }

  $ wax loop.wat -f wax | wax -i wax -f wat
  (func $f (export "f") (param $n i32) (result i32)
    (loop $l_2 (result i32) (br_if $l_2 (local.get $n)) (i32.const 9))
  )

…and so does a `try_table` (here in `return` position):

  $ wax try_table.wat -f wax
  tag e();
  #[export = "f"]
  fn f() -> i32 {
      'h: do {
          return
              try {
                  5;
              } catch [ _ -> 'h];
      }
      7;
  }

  $ wax try_table.wat -f wax | wax -i wax -f wat
  (tag $e)
  (func $f (export "f") (result i32)
    (block $h (return (try_table (result i32) (catch_all $h) (i32.const 5))))
    (i32.const 7)
  )
