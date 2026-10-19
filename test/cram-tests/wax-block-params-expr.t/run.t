A block, loop or if used as an expression has no stack to draw from, so it
cannot take parameters. This is reported, rather than crashing the
type-checker:

  $ wax check block.wax
  Error: A block, loop or if used as an expression cannot take parameters.
   ──➤  block.wax:1:33
  1 │ fn f() -> i32 { _ = 1 as i32 + (do (i32) -> i32 { }); 0 as i32; }
    ·                                 ^^^^^^^^^^^^^^^^^^^
  2 │ 
  [128]

  $ wax check loop.wax
  Error: A block, loop or if used as an expression cannot take parameters.
   ──➤  loop.wax:1:26
  1 │ fn f() { _ = 1 as i32 + (loop (i32) -> i32 { }); }
    ·                          ^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [128]

  $ wax check if.wax
  Error: A block, loop or if used as an expression cannot take parameters.
   ──➤  if.wax:1:22
  1 │ fn f() -> i32 { _ = (if 1 as i32 => (i32) -> i32 { } else { }); 0 as i32; }
    ·                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [128]

A legacy try takes the same path, both with and without an expected type:

  $ wax check try.wax
  Error: A block, loop or if used as an expression cannot take parameters.
   ──➤  try.wax:1:26
  1 │ fn f() { _ = 1 as i32 + (try_legacy (i32) -> i32 { } catch { }); }
    ·                          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  Error: Expecting 1 returned value(s) from the stack, but there are 0.
   ──➤  try.wax:1:62
  1 │ fn f() { _ = 1 as i32 + (try_legacy (i32) -> i32 { } catch { }); }
    ·                                                              ^
  2 │ 
  [128]

  $ wax check try-expected.wax
  Error: A block, loop or if used as an expression cannot take parameters.
   ──➤  try-expected.wax:1:30
  1 │ fn f() -> i32 { let x: i32 = try_legacy (i32) -> i32 { } catch { }; x; }
    ·                              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  Error: Expecting 1 returned value(s) from the stack, but there are 0.
   ──➤  try-expected.wax:1:66
  1 │ fn f() -> i32 { let x: i32 = try_legacy (i32) -> i32 { } catch { }; x; }
    ·                                                                  ^
  2 │ 
  [128]
