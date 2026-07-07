The same three lints on Wax source, in the type checker.

`unused-import` — an imported function or global never used; `_` silences it:

  $ wax check -W unused=warning imports.wax
  Warning: The imported function 'dead' is never used.
   ──➤  imports.wax:3:8
  1 │ import "m" {
  2 │     fn used() -> i32;
  3 │     fn dead() -> i32;
    ·        ^^^^
  4 │     #[import = "ignored"] const _ignored: i32;
  5 │ }

`redundant-operation` (off by default) — an identity/absorbing/self operation:

  $ wax check -W redundant=warning redundant.wax
  Warning: This operation has no effect on its result.
   ──➤  redundant.wax:2:26
  1 │ #[export = "id"]
  2 │ fn id(x: i32) -> i32 { x + 0; }
    ·                          ^
  3 │ 
  4 │ #[export = "zero"]
  Warning: This operation always yields 0.
   ──➤  redundant.wax:5:28
  3 │ 
  4 │ #[export = "zero"]
  5 │ fn zero(x: i32) -> i32 { x * 0; }
    ·                            ^
  6 │ 
  7 │ #[export = "same"]
  Warning: This operation always yields 0.
    ──➤  redundant.wax:8:28
   6 │ 
   7 │ #[export = "same"]
   8 │ fn same(x: i32) -> i32 { x ^ x; }
     ·                            ^
   9 │ 
  10 │ #[export = "selfset"]
  Warning: This assignment writes the variable back to itself.
    ──➤  redundant.wax:11:40
   9 │ 
  10 │ #[export = "selfset"]
  11 │ fn selfset(y: i32) -> i32 { let x = y; x = x; x; }
     ·                                        ^^^^^
  12 │ 

`cast-always-fails` (shown by default) plus the redundant cast (off by default):

  $ wax check -W redundant=warning casts.wax
  Warning: This cast is redundant: the value already has this type.
   ──➤  casts.wax:6:29
  4 │ 
  5 │ #[export = "redundant"]
  6 │ fn redundant(a: &A) -> &A { a as &A; }
    ·                             ^^^^^^^
  7 │ 
  8 │ #[export = "downcast"]
