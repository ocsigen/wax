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

The type also flows in from the context — a function's return type, a typed
binding, or a call argument. So an `if` whose branches all diverge, or carry
their value out via a `br` to the if's own label, still gets a type even with
no fall-through value of its own:

  $ wax check both-diverge.wax

  $ wax check self-branch.wax

When the type cannot be determined it is reported. The branches must agree; in a
checked position the offending branch is pointed at:

  $ wax check mismatched.wax
  Error: This instruction has type &any but is expected to have type i64.
   ──➤  mismatched.wax:2:31
  1 │ fn f(c: i32) -> i64 {
  2 │     if c { 0 as i64; } else { null as &any; }
    ·                               ^^^^^^^^^^^^
  3 │ }
  4 │ 
  [123]

A value-producing `if` needs an `else`:

  $ wax check no-else.wax
  Error: This 'if' must produce a value and so requires an 'else' branch.
   ──➤  no-else.wax:2:5
  1 │ fn f(c: i32) -> i32 {
  2 │     if c { 1; }
    ·     ^^^^^^^^^^^
  3 │ }
  4 │ 
  [123]

With no context to draw on (here a method receiver, typed in synthesis), the two
branches have no common supertype, so a caret points at each branch's value and
is labelled with its type (and, since the types are in incompatible hierarchies,
no `=> T` annotation could reconcile them, so none is suggested):

  $ wax check mismatched-synth.wax
  Error:
    The branches of this if produce values with no common supertype, so its result type cannot be inferred.
   ──➤  mismatched-synth.wax:2:6
  1 │ fn f(c: i32) -> i32 {
  2 │     (if c { 0 as i64; } else { null as &any; }).clz() as i32;
    ·      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    ·             ^^^^^^^^ i64
    ·                                ^^^^^^^^^^^^ &any
  3 │ }
  4 │ 
  [123]
