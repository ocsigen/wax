Error recovery in the Wax typer: one root fault yields one well-anchored
report, with no cascades at other sites and no silent acceptance (the typer
mirror of the validator's poisoned index entries; see
TYPING-FINDINGS-TRIAGE.md).

An unbound construction type name is an error (it used to be silently
accepted and lowered to `unreachable`), with a did-you-mean hint, for struct
and array literals alike.

  $ cat > construction.wax <<'WAX'
  > type point = { x: i32 };
  > type arr = [i32];
  > fn f() -> i32 {
  >     let _v = {poimt| x: 1};
  >     let _w = [arrr| 1, 2];
  >     2;
  > }
  > WAX
  $ wax check construction.wax
  Error: The type 'poimt' is not bound.
   ──➤  construction.wax:4:15
  2 │ type arr = [i32];
  3 │ fn f() -> i32 {
  4 │     let _v = {poimt| x: 1};
    ·               ^^^^^
  5 │     let _w = [arrr| 1, 2];
  6 │     2;
  Hint: Did you mean 'point'?
  Error: The type 'arrr' is not bound.
   ──➤  construction.wax:5:15
  3 │ fn f() -> i32 {
  4 │     let _v = {poimt| x: 1};
  5 │     let _w = [arrr| 1, 2];
    ·               ^^^^
  6 │     2;
  7 │ }
  Hint: Did you mean 'arr'?
  [128]

A function whose signature fails to resolve is poison-registered: its own
error is reported once, its body is STILL checked (an unbound callee there
surfaces), and callers of the broken function stay quiet.

  $ cat > signature.wax <<'WAX'
  > fn broken(x: &bad_type) -> i32 {
  >     let y = x;
  >     g(y);
  >     g(y);
  >     1;
  > }
  > fn caller() -> i32 { broken(3); }
  > WAX
  $ wax check --error-format short signature.wax
  signature.wax:1:15: error: The type 'bad_type' is not bound.
  signature.wax:3:5: error: The variable 'g' is not bound.
  signature.wax:4:5: error: The variable 'g' is not bound.
  [128]

A failed producer poisons the pending stack, so hole consumers absorb it
silently instead of reporting arity errors away from the fault.

  $ cat > producer.wax <<'WAX'
  > fn h(a: i32, b: i32) -> i32 { a + b; }
  > fn f() -> i32 {
  >     g();
  >     h(_, _);
  > }
  > WAX
  $ wax check --error-format short producer.wax
  producer.wax:3:5: error: The variable 'g' is not bound.
  [128]

An unbound label on a value-carrying branch reports once at the label; the
fall-through values pass through with their real arity and types, so the
consumers below type-check cleanly.

  $ cat > label.wax <<'WAX'
  > type t = { a: i32 };
  > fn use(n: i32, r: &t) -> i32 { n + r.a; }
  > fn f(n: i32, r: &?t) -> i32 {
  >     'l: do {
  >         br_on_null 'nolabel (n, r);
  >         return use(_, _);
  >     }
  >     0;
  > }
  > WAX
  $ wax check --error-format short label.wax
  label.wax:5:20: error: The label 'nolabel' is not bound.
  [128]

A non-constant leaf in a nested constant binop chain reports once, at the
innermost offender, not once per enclosing level.

  $ cat > chain.wax <<'WAX'
  > fn h() -> f64 { 1.5; }
  > let d = 1 * (2 * h());
  > WAX
  $ wax check --error-format short chain.wax
  chain.wax:2:18: error: Only constant expressions are allowed here.
  [128]

A `br_table` target repeated in the list is checked and reported once (labels
are names in one scope, so identical spellings are one target); two distinct
mismatching targets still get one report each.

  $ cat > br-table.wax <<'WAX'
  > fn f(i: i32) -> i32 {
  >     'out: do i32 {
  >         br_table ['out, 'out, else 'out] (1.5, i);
  >     };
  > }
  > fn g(i: i32) -> i32 {
  >     'a: do i32 {
  >         'b: do i32 {
  >             br_table ['b, else 'a] (1.5, i);
  >         };
  >     };
  > }
  > WAX
  $ wax check --error-format short br-table.wax
  br-table.wax:3:42: error: This instruction has type 'float' but is expected to have type 'i32'.
  br-table.wax:9:36: error: This instruction has type 'float' but is expected to have type 'i32'.
  br-table.wax:9:36: error: This instruction has type 'float' but is expected to have type 'i32'.
  br-table.wax:7:5: error: The values reaching this block's exit have no common supertype, so its result type cannot be inferred.
  [128]
