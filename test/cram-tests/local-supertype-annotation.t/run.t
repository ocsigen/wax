Converting Wasm to Wax fuses a local's declaration with its first assignment
into a `let` binding and drops the type annotation when it is redundant. A local
that no later assignment writes is effectively immutable, so — like a `const`
global — its annotation is dropped not only when it equals the initializer's
type but also when it is a mere supertype of it, narrowing the local to that
subtype. A local that is assigned again keeps the wider annotation, which the
later assignment relies on.

  $ wax -i wat -f wax locals.wat
  type s = open { f: i32 };
  fn f() -> i32 {
      0;
  }
  fn write_once() -> &?func {
      let x = f;
      x;
  }
  fn reassigned() -> &?func {
      let y: &?func = f;
      y = null;
      y;
  }
  fn write_once_struct() -> &?eq {
      let z = { f: 7 };
      z;
  }
