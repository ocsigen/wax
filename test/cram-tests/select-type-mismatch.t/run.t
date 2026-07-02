A conditional expression `c ? a : b` compiles to a `select`, whose two arms must
have a common supertype. When they don't — here `i64` and `&any`, in
incompatible type hierarchies — a caret points at each arm, labelled with its
type. (As with an `if`, no annotation could reconcile them, so none is
suggested.)

  $ wax check mismatch.wax
  Error:
    The two branches of this select have no common supertype, so its result type cannot be inferred.
   ──➤  mismatch.wax:2:6
  1 │ fn f(c: i32) -> i32 {
  2 │     (c ? 0 as i64 : null as &any).clz() as i32;
    ·      ^^^^^^^^^^^^^^^^^^^^^^^^^^^
    ·          ^^^^^^^^ i64
    ·                     ^^^^^^^^^^^^ &any
  3 │ }
  4 │ 
  [128]
