An instruction method or field access on a hole '_' whose type is still
unconstrained (e.g. in dead code after 'unreachable') cannot be resolved, so the
access is rejected with a diagnostic pointing at the receiver rather than
collapsing or crashing:

  $ wax check method.wax
  Error:
    Cannot determine the type of this expression, which is needed to compile this operation.
   ──➤  method.wax:1:34
  1 │ fn f() -> f32 { unreachable; _ = _.ceil(); }
    ·                                  ^
  2 │ 
  [123]

  $ wax check field.wax
  Error:
    Cannot determine the type of this expression, which is needed to compile this operation.
   ──➤  field.wax:2:34
  1 │ type s = { x: i32 };
  2 │ fn f() -> i32 { unreachable; _ = _.x; }
    ·                                  ^
  3 │ 
  [123]
