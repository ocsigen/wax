A reference-to-integer cast (`ref as iN_s/u`) extracts an i31 payload: it lowers
to a `ref.cast (ref i31)` then an `i31.get`. So an `any`-hierarchy reference that
can never be an i31 — a struct or array, not `any`/`eq`/`i31` — makes that hidden
`ref.cast` always trap.

The Wasm validator has always reported this on the lowered form; the Wax typer
used to miss it because its cast lint only matched reference→reference casts, not
the ref→numeric one. Now the typer flags it too (lint parity). Regression: the
lint-parity fuzz oracle (wax vs wat) flagged the one-sided `cast-always-fails`.

  $ cat > m.wax <<'WAX'
  > type arr = [mut i16];
  > #[export]
  > fn f() -> i32 {
  >     [arr| d @ 0; 2] as i32_u;
  > }
  > data d = "\x00\x11\x22\x33";
  > WAX
  $ wax check -W cast-always-fails=warning m.wax
  Warning [cast-always-fails]:
    This cast always traps: the value can never have this type.
   ──➤  m.wax:4:5
  2 │ #[export]
  3 │ fn f() -> i32 {
  4 │     [arr| d @ 0; 2] as i32_u;
    ·     ^^^^^^^^^^^^^^^^^^^^^^^^
  5 │ }
  6 │ data d = "\x00\x11\x22\x33";

A cast of an `any`/`eq`/`i31` reference (which can be an i31 at runtime) is not
flagged — only a provably-disjoint heap type is. Checked here through the WAT
validator, which mirrors the same rule:

  $ cat > n.wat <<'WAT'
  > (module (func (export "f") (param (ref any)) (result i32)
  >   (i31.get_u (ref.cast (ref i31) (local.get 0)))))
  > WAT
  $ wax check -W cast-always-fails=warning n.wat

Only the INNERMOST cast of a chain is reported. Once a cast can never produce a
value, whatever an outer cast or test says about that value merely follows from
the inner verdict, and the fix belongs at the inner cast. Nested casts also share
a start position, so the two reports would print as the same `line:col: message`
to a `--error-format short`/`json` consumer. Regression: found by the mutation
fuzzer's duplicate-diagnostic oracle.

  $ cat > chain.wax <<'WAX'
  > type a = open { x: i32 };
  > type b = { y: i64 };
  > type c: a = { x: i32, z: i32 };
  > #[export]
  > fn f(p: &a) -> i32 {
  >     p as &b as &c is &a;
  > }
  > WAX
  $ wax check -W correctness=warning --error-format short chain.wax
  chain.wax:6:5: warning: This cast always traps: the value can never have this type. [cast-always-fails]

Each cast on its own is still reported:

  $ cat > single.wax <<'WAX'
  > type a = open { x: i32 };
  > type b = { y: i64 };
  > #[export]
  > fn f(p: &a) -> i32 {
  >     !(p as &b);
  > }
  > #[export]
  > fn g(p: &a) -> i32 {
  >     !(p as &b);
  > }
  > WAX
  $ wax check -W correctness=warning --error-format short single.wax
  single.wax:5:7: warning: This cast always traps: the value can never have this type. [cast-always-fails]
  single.wax:9:7: warning: This cast always traps: the value can never have this type. [cast-always-fails]

The chain rule covers only the always-trapping verdict. A REDUNDANT outer cast is
an independent claim — its target is the type the operand already has, whatever
that operand does at run time — with its own fix (delete that cast), and each
source cast lowers to its own `ref.cast`, so the Wasm validator reports it on the
lowered form. Suppressing it here left the wat form of the chain below linted and
the wax form silent. Regression: found by the lint-parity fuzz oracle.

  $ cat > redundant-chain.wax <<'WAX'
  > import "m" fn g();
  > #[export]
  > fn f() -> &func {
  >     g as &fn(i32) -> i32 as &fn(i32) -> i32;
  > }
  > WAX
  $ wax check -W correctness=warning -W redundant-operation=warning --error-format short redundant-chain.wax
  redundant-chain.wax:4:5: warning: This cast always traps: the value can never have this type. [cast-always-fails]
  redundant-chain.wax:4:5: warning: This cast is redundant: the value already has this type. [redundant-operation]

The same two warnings on the lowered form, where the two casts have distinct
start columns (a Wax cast chain shares one, since each cast's span starts at the
innermost operand):

  $ wax -i wax -f wat redundant-chain.wax -o redundant-chain.wat
  $ wax check -W correctness=warning -W redundant-operation=warning --error-format short redundant-chain.wat
  redundant-chain.wat:4:6: warning: This cast always traps: the value can never have this type. [cast-always-fails]
  redundant-chain.wat:3:4: warning: This cast is redundant: the value already has this type. [redundant-operation]
