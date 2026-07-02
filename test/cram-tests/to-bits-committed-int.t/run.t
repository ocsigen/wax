[to_bits] reinterprets a float's bits as an integer, so it needs a float
receiver. A bare integer literal (possibly a decompiled integer-valued float
constant) is still flexible and coerces to f64, but a receiver already committed
to the integer family — the result of an integer operation such as [clz] — must
be rejected. Typing wrongly accepted such a receiver and coerced its type cell to
f64; because [clz] shares that cell with its own operand, [to_wasm] then lowered
[clz] against an f64 operand and hit an assertion. It is now a clean type error.
Regression: found by the AST-mutation fuzzer.

  $ cat > m.wax <<'WAX'
  > fn f() -> i64 {
  >     (0).clz().to_bits();
  > }
  > WAX

  $ wax check m.wax
  Error: This operation cannot be applied to a value of type int.
   ──➤  m.wax:2:15
  1 │ fn f() -> i64 {
  2 │     (0).clz().to_bits();
    ·               ^^^^^^^
  3 │ }
  4 │ 
  [128]

A legitimate float receiver (here a bare float literal) still round-trips.

  $ cat > ok.wax <<'WAX'
  > #[export = "g"]
  > fn g() -> i64 {
  >     (1.5).to_bits();
  > }
  > WAX

  $ wax ok.wax -f wat
  (func $g (export "g") (result i64) (i64.reinterpret_f64 (f64.const 1.5)))
