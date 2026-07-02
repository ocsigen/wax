A function declared with a type reference (`fn f: T`) requires `T` to be a
function type, just as a tag does.

  $ wax check bad.wax
  Error: Expected function type.
   ──➤  bad.wax:2:30
  1 │ type point = { x: i32, y: i32 };
  2 │ #[import = ("m", "n")] fn f: point;
    ·                              ^^^^^
  3 │ 
  [128]

A reference to an actual function type is accepted:

  $ wax check ok.wax

When both a type reference and an inline signature are given, the inline
signature must match the referenced type (this holds for tags too):

  $ wax check inline-ok.wax

  $ wax check inline-bad.wax
  Error: The inline function type does not match the type definition.
   ──➤  inline-bad.wax:2:30
  1 │ type ft = fn(i32) -> i32;
  2 │ #[import = ("m", "n")] fn f: ft (f64) -> f64;
    ·                              ^^
  3 │ 
  [128]

  $ wax check tag-inline-bad.wax
  Error: The inline function type does not match the type definition.
   ──➤  tag-inline-bad.wax:2:8
  1 │ type ft = fn(i32) -> i32;
  2 │ tag t: ft (f64);
    ·        ^^
  3 │ 
  [128]
