Cases where the type checker used to accept invalid input or emit wrong output,
now rejected in line with the Wasm validator ("Wax typing mirrors Wasm
validation").

`become` cannot apply to a stack-switching operation: it is not a call, so no
tail call can be formed and the return-type check would be skipped. It used to
compile to the plain operation, silently dropping the marker; now it is a
diagnostic. On a `resume`:

  $ cat > become-resume.wax <<'WAX'
  > type ft = fn() -> i32;
  > type k = cont ft;
  > fn f(c: &k) -> i32 { become c.resume(); }
  > WAX

  $ wax check become-resume.wax
  Error: 'become' cannot apply to a stack-switching operation.
   ──➤  become-resume.wax:3:22
  1 │ type ft = fn() -> i32;
  2 │ type k = cont ft;
  3 │ fn f(c: &k) -> i32 { become c.resume(); }
    ·                      ^^^^^^^^^^^^^^^^^
  4 │ 
  [128]

...and on a continuation constructor (`k::new`):

  $ cat > become-new.wax <<'WAX'
  > type ft = fn() -> i32;
  > type k = cont ft;
  > fn ff() -> i32 { 5; }
  > fn g() -> &k { become k::new(ff); }
  > WAX

  $ wax check become-new.wax
  Error: 'become' cannot apply to a stack-switching operation.
   ──➤  become-new.wax:4:16
  2 │ type k = cont ft;
  3 │ fn ff() -> i32 { 5; }
  4 │ fn g() -> &k { become k::new(ff); }
    ·                ^^^^^^^^^^^^^^^^^
  5 │ 
  [128]

A genuine tail call is still accepted and lowers to `return_call`:

  $ cat > become-ok.wax <<'WAX'
  > fn g(x: i32) -> i32 { x; }
  > fn f(x: i32) -> i32 { become g(x); }
  > WAX

  $ wax -f wat become-ok.wax
  (func $g (param $x i32) (result i32) (local.get $x))
  (func $f (param $x i32) (result i32) (return_call $g (local.get $x)))

`v128::bitselect` takes exactly three operands; an under- or over-application is
now rejected in the type checker rather than slipping through to an unrelated
stack error during lowering:

  $ cat > bitselect.wax <<'WAX'
  > fn few(a: v128, b: v128) -> v128 { a; b; v128::bitselect(_, _); }
  > fn many(a: v128, b: v128, c: v128, d: v128) -> v128 {
  >   a; b; c; d; v128::bitselect(_, _, _, _);
  > }
  > WAX

  $ wax check bitselect.wax
  Error: This instruction provides 2 value(s) but 3 was/were expected.
   ──➤  bitselect.wax:1:42
  1 │ fn few(a: v128, b: v128) -> v128 { a; b; v128::bitselect(_, _); }
    ·                                          ^^^^^^^^^^^^^^^^^^^^^
  2 │ fn many(a: v128, b: v128, c: v128, d: v128) -> v128 {
  3 │   a; b; c; d; v128::bitselect(_, _, _, _);
  Error: This instruction provides 4 value(s) but 3 was/were expected.
   ──➤  bitselect.wax:3:15
  1 │ fn few(a: v128, b: v128) -> v128 { a; b; v128::bitselect(_, _); }
  2 │ fn many(a: v128, b: v128, c: v128, d: v128) -> v128 {
  3 │   a; b; c; d; v128::bitselect(_, _, _, _);
    ·               ^^^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │ }
  5 │ 
  [128]

The three-operand form is accepted:

  $ cat > bitselect-ok.wax <<'WAX'
  > fn ok(a: v128, b: v128, c: v128) -> v128 { a; b; c; v128::bitselect(_, _, _); }
  > WAX

  $ wax check bitselect-ok.wax

The length of an `array.new_default` (`[..; n]`) must be a constant expression,
like every other constant leaf's operand; a non-constant length is now rejected
by `check` instead of being caught only later at lowering:

  $ cat > array-default.wax <<'WAX'
  > type a = [mut i32];
  > fn len() -> i32 { 5; }
  > let g: &a = [..; len()];
  > WAX

  $ wax check array-default.wax
  Error: Only constant expressions are allowed here.
   ──➤  array-default.wax:3:18
  1 │ type a = [mut i32];
  2 │ fn len() -> i32 { 5; }
  3 │ let g: &a = [..; len()];
    ·                  ^^^^^
  4 │ 
  [128]

A `#![feature]` declaration inside a conditional used to be accepted yet never
applied (so the constructs it was meant to enable still errored); it is now a
placement error:

  $ cat > feature-in-if.wax <<'WAX'
  > #[if(x)] {
  >   #![feature = "custom-descriptors"]
  > }
  > WAX

  $ wax check feature-in-if.wax
  Error:
    A '#![feature = "…"]' declaration states a fact about the whole module and
    must appear at the top level, not inside a conditional.
   ──➤  feature-in-if.wax:2:16
  1 │ #[if(x)] {
  2 │   #![feature = "custom-descriptors"]
    ·                ^^^^^^^^^^^^^^^^^^^^
  3 │ }
  4 │ 
  [128]

Resolving the conditional with a define promotes the declaration to the top
level, where it is applied normally:

  $ wax check -D x=true feature-in-if.wax
