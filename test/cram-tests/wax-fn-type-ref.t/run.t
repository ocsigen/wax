A function declared with a type reference (`fn f: T`) requires `T` to be a
function type, just as a tag does.

  $ wax check bad.wax
  Error: Expected function type.
   ──➤  bad.wax:2:30
  1 │ type point = { x: i32, y: i32 };
  2 │ #[import = ("m", "n")] fn f: point;
    ·                              ^^^^^
  3 │ 
  [123]

A reference to an actual function type is accepted:

  $ wax check ok.wax
