A condition variable is shared by WAT, Wax and -D, so it must be a valid Wax
identifier. A WAT name that is not one is rejected.

  $ wax check dash.wat
  Error:
    A condition variable must be a valid Wax identifier, which '$portable-int'
    is not.
   ──➤  dash.wat:2:8
  1 │ (module
  2 │   (@if $portable-int
    ·        ^^^^^^^^^^^^^
  3 │    (@then (global $g i32 (i32.const 0)))))
  4 │ 
  [128]

So is a -D name.

  $ NO_COLOR=1 wax -D portable-int=true -f wat keyword.wat
  Usage: wax [--help] [COMMAND] …
  wax: option '-D': 'portable-int' is not a valid variable name (a Wax
       identifier)
  [124]

A keyword is a valid variable name: Wax accepts it in a condition, as it does
for a label, so such a variable round-trips.

  $ wax -f wax keyword.wat
  #[if(all(if, type = "wasi"))]
  {
      const g = 0;
  }
  #[else]
  {
      const g = 1;
  }
  #[export]
  fn f() -> i32 {
      #[if(loop)]
      {
          return 1;
      }
      g;
  }
  $ wax -f wat keyword.wax
  (@if (and $if (= $type "wasi"))
    (@then (global $g i32 (i32.const 0)))
    (@else (global $g i32 (i32.const 1)))
  )
  (func $f (export "f") (result i32)
    (@if $loop (@then (return (i32.const 1))))
    (return (global.get $g))
  )
  $ wax -D if=true -D type=wasi -D loop=false -f wat keyword.wax
  (global $g i32 (i32.const 0))
  (func $f (export "f") (result i32) (return (global.get $g)))
