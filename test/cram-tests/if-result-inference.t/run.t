A value-producing `if` infers its result type from the values reaching its exit
(its branch tails), so converting from Wasm drops the redundant `=> T`:

  $ wax convert --input-format wat --format wax infer.wat
  #[export = "f"]
  fn f(c: i32) -> i32 {
      if c {
          1;
      } else {
          2;
      }
  }

That type is recovered on re-parse, so it is only dropped when inference would
recover it. The cases below cannot be inferred and are reported.

The two branches must share a type; here `i64` and `&any` have none:

  $ wax check mismatched.wax
  Error:
    The branches of this if produce values with no common supertype, so its result type cannot be inferred; their types are respectively
    i64 and &any. Add an explicit => T result type.
   ──➤  mismatched.wax:2:5
  1 │ fn f(c: i32) -> i64 {
  2 │     if c { 0 as i64; } else { null as &any; }
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  3 │ }
  4 │ 
  [123]

Inference needs both arms — an `if` with no `else` cannot produce a value:

  $ wax check no-else.wax
  Error: This value remains on the stack.
   ──➤  no-else.wax:2:12
  1 │ fn f(c: i32) -> i32 {
  2 │     if c { 1; }
    ·            ^
  3 │ }
  4 │ 
  Error: The stack is empty.
   ──➤  no-else.wax:1:1
  1 │ fn f(c: i32) -> i32 {
    · ^^^^^^^^^^^^^^^^^^^^^^
  2 │     if c { 1; }
    · ^^^^^^^^^^^^^^^^
  3 │ }
    · ^
  4 │ 
  [123]

A value reaching the exit via a `br` to the `if`'s own label is not inferred
(its value would be lost on re-parse); the explicit `=> T` is required:

  $ wax check self-branch.wax
  Error: This instruction provides 1 value(s) but 0 was/were expected.
   ──➤  self-branch.wax:2:22
  1 │ fn f(c: i32) -> i32 {
  2 │     'l: if c { br 'l 1; } else { 2; }
    ·                      ^
  3 │ }
  4 │ 
  Error: This value remains on the stack.
   ──➤  self-branch.wax:2:34
  1 │ fn f(c: i32) -> i32 {
  2 │     'l: if c { br 'l 1; } else { 2; }
    ·                                  ^
  3 │ }
  4 │ 
  Error: The stack is empty.
   ──➤  self-branch.wax:1:1
  1 │ fn f(c: i32) -> i32 {
    · ^^^^^^^^^^^^^^^^^^^^^^
  2 │     'l: if c { br 'l 1; } else { 2; }
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  3 │ }
    · ^
  4 │ 
  [123]

  $ wax check self-branch-ok.wax

When both branches diverge there is no fall-through value to infer from, so a
value-position `if` must state its type:

  $ wax check both-diverge.wax
  Error: The stack is empty.
   ──➤  both-diverge.wax:1:1
  1 │ fn f(c: i32) -> i32 {
    · ^^^^^^^^^^^^^^^^^^^^^^
  2 │     if c { return 1; } else { return 2; }
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  3 │ }
    · ^
  4 │ 
  [123]

  $ wax check both-diverge-ok.wax
