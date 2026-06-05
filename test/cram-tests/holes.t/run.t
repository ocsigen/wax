Well placed holes

  $ wax good.wax -o /dev/null

A constant before the last hole

  $ wax bad1.wax -o /dev/null
  Error: This expression occurs before a hole '_'.
   ──➤  bad1.wax:3:15
  1 │ 
  2 │ fn f () -> i32 {
  3 │   1; 3;  _ + (2 + _);
    ·               ^
  4 │ }
  5 │ 
  [128]

A binary operation before the last hole

  $ wax bad2.wax -o /dev/null
  Error: This expression occurs before a hole '_'.
   ──➤  bad2.wax:3:13
  1 │ 
  2 │ fn f () -> i32 {
  3 │   1; 2; 3;  _ + _ + _;
    ·             ^^^^^
  4 │ }
  5 │ 
  [128]

Struct fields are ordered according to the type

  $ wax bad3.wax -o /dev/null
  Error: This expression occurs before a hole '_'.
   ──➤  bad3.wax:4:18
  2 │ 
  3 │ fn i () -> &t {
  4 │   1; {t| y:_, x: 1};
    ·                  ^
  5 │ }
  6 │ 
  [128]


Function arguments are before the function itself

  $ wax bad4.wax -o /dev/null
  Error: This expression occurs before a hole '_'.
   ──➤  bad4.wax:7:8
  5 │ 
  6 │ fn j () -> i32 {
  7 │   f; _(1);
    ·        ^
  8 │ }
  9 │ 
  [128]

Select condition is considered after the two branches

  $ wax bad5.wax -o /dev/null
  Error: This expression occurs before a hole '_'.
   ──➤  bad5.wax:2:8
  1 │ fn k (x: i32) -> i32 {
  2 │   x; _?1:2;
    ·        ^
  3 │ }
  4 │ 
  [128]
