A synthesized type — a string's byte array, or the type of a function declared
with an inline signature — has no meaningful source name (internally [<string>]
or [<fn:..>]). A diagnostic that mentions such a type renders its composite type
inline ([mut i8] / fn(..) -> ..) rather than that synthetic name.

A bare string is a [mut i8] byte array:

  $ wax check string.wax
  Error: This instruction has type [mut i8] but is expected to have type i32.
   ──➤  string.wax:2:5
  1 │ fn f() -> i32 {
  2 │     "hi";
    ·     ^^^^
  3 │ }
  4 │ 
  [128]

A function declared with an inline signature, referenced as a value:

  $ wax check funcref.wax
  Error: Expecting type i32 but got type fn(i32) -> i32.
   ──➤  funcref.wax:6:5
  4 │ 
  5 │ fn f() -> i32 {
  6 │     g;
    ·     ^
  7 │ }
  8 │ 
  [128]

A cast to an inline function type [&fn(..)]:

  $ wax check cast.wax
  Error: Expecting type i32 but got type fn(i32) -> i32.
   ──➤  cast.wax:5:6
  3 │ 
  4 │ fn f() -> i32 {
  5 │     (g as &fn(i32) -> i32);
    ·      ^^^^^^^^^^^^^^^^^^^^
  6 │ }
  7 │ 
  [128]

The inline function type is minted while type-checking, so it lies outside the
snapshot the subtyping info was first built from. Subtyping against it (here
[&fn(i32) -> i32] against the declared result [&func]) must still work — the
info is rebuilt on demand — rather than crash with an out-of-bounds index:

  $ wax check subtype.wax
