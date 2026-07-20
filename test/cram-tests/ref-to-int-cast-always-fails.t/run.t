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
