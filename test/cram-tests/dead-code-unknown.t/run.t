A type-unknown operation in unreachable code is rejected: even though dead code
type-checks permissively, an operation whose compilation needs the operand's
concrete type (an array/struct access, a call, …) cannot be emitted when that
type is unknown. The diagnostic points at the offending operand:

  $ wax check dead.wax
  Error:
    Cannot determine the type of this expression, which is needed to compile this operation.
   ──➤  dead.wax:7:5
  5 │ fn f() -> i32 {
  6 │     unreachable;
  7 │     _[0];
    ·     ^
  8 │ }
  9 │ 
  Error:
    Cannot determine the type of this expression, which is needed to compile this operation.
    ──➤  dead.wax:16:13
  14 │ fn g() {
  15 │     unreachable;
  16 │     let b = _.v;
     ·             ^
  17 │     let _ = b;
  18 │ }
  [128]
