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
