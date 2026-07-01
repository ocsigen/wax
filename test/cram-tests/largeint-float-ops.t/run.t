A "large number" (an integer literal too big for i32) is float-capable: i64, f32
or f64. Several one-operand-known type-checker arms had not been threaded through
it, unlike "number" / "float" beside them.

A float intrinsic (`sqrt`/`abs`/`ceil`/`floor`/`trunc`/`nearest`) takes it as a
float, like a `number` receiver — this used to be rejected:

  $ cat > a.wax <<'WAX'
  > fn f() -> f64 {
  >     (5000000000).sqrt();
  > }
  > WAX
  $ wax -i wax a.wax -f wat
  (func $f (result f64) (f64.sqrt (f64.const 5000000000)))

A float comparison against a polymorphic (dead-code) value likewise takes it as a
float rather than rejecting it as "large number and large number":

  $ cat > b.wax <<'WAX'
  > fn f(x: f64) -> i32 {
  >     unreachable;
  >     _ < 5000000000;
  > }
  > WAX
  $ wax -i wax b.wax -f wasm -o /dev/null --validate

Dually, `!` on a large number is an integer test, so it pins to i64 (`i64.eqz`)
rather than staying float-capable — there is no float `eqz`:

  $ cat > c.wax <<'WAX'
  > fn f() -> i32 {
  >     !5000000000;
  > }
  > WAX
  $ wax -i wax c.wax -f wat
  (func $f (result i32) (i64.eqz (i64.const 5000000000)))
