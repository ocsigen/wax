An intrinsic method on a hole '_' whose type is still unconstrained (e.g. in
dead code after 'unreachable') is resolved from the method name alone: 'ceil' is
a float operation, so the receiver defaults to its natural width rather than
failing to compile. This mirrors how an abstract numeric receiver is handled,
and lets the decompiler round-trip such intrinsics from unreachable code.

  $ wax -f wax method.wax
  fn f() -> f32 {
      unreachable;
      _ = _.ceil();
  }

A plain field access, by contrast, genuinely needs the receiver's concrete type
to resolve the field, so it is still rejected with a diagnostic pointing at the
receiver rather than collapsing or crashing:

  $ wax check field.wax
  Error:
    Cannot determine the type of this expression, which is needed to compile this operation.
   ──➤  field.wax:2:34
  1 │ type s = { x: i32 };
  2 │ fn f() -> i32 { unreachable; _ = _.x; }
    ·                                  ^
  3 │ 
  [123]
