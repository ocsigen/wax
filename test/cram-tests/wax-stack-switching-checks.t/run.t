Wax type-checking performs the structural stack-switching checks that the Wasm
validator does, rather than deferring them to the compiled module.

A continuation type must wrap a function type:

  $ wax check cont-not-func.wax
  Error: Expected function type.
   ──➤  cont-not-func.wax:1:16
  1 │ type ct = cont ct;
    ·                ^^
  2 │ 
  [123]

Continuation types cannot be the target of a cast instruction (ref.cast,
ref.test, br_on_cast, br_on_cast_fail):

  $ wax check cast-cont.wax
  Error: Continuation types cannot be used in a cast instruction.
   ──➤  cast-cont.wax:1:27
  1 │ fn f() { unreachable; _ = _ as &?cont; }
    ·                           ^^^^^^^^^^^
  2 │ 
  [123]

  $ wax check test-cont.wax
  Error: Continuation types cannot be used in a cast instruction.
   ──➤  test-cont.wax:1:27
  1 │ fn f() { unreachable; _ = _ is &?cont; }
    ·                           ^
  2 │ 
  [123]

  $ wax check br-on-cast-cont.wax
  Error: Continuation types cannot be used in a cast instruction.
   ──➤  br-on-cast-cont.wax:1:43
  1 │ fn f() { _ = 'l: do &?cont { unreachable; br_on_cast 'l &?cont _; }; }
    ·                                           ^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [123]

A resume handler label must receive the tag's parameters followed by a
continuation of the remaining result type:

  $ wax check resume-handler.wax
  Error: Type mismatch in this stack switching instruction:
    this handler must take the tag's parameters followed by a continuation of the remaining result type.
   ──➤  resume-handler.wax:7:31
  5 │     _ =
  6 │         'on_foo: do &ft {
  7 │             resume ct [foo -> 'on_foo](null as &?ct);
    ·                               ^^^^^^^
  8 │             unreachable;
  9 │         };
  [123]

A cont.bind's destination continuation must match the source with its leading
parameters bound away:

  $ wax check cont-bind-mismatch.wax
  Error: Type mismatch in this stack switching instruction:
    the bound parameters and results do not match between the two continuation types.
   ──➤  cont-bind-mismatch.wax:5:25
  3 │ type ft1_alt = fn(i64) -> i32;
  4 │ type ct1_alt = cont ft1_alt;
  5 │ fn error(p: &ct2) { _ = cont_bind ct2 ct1_alt(123 as i64, p); }
    ·                         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  6 │ 
  [123]

Well-formed stack-switching code passes (a null cast to a nullable continuation
reference lowers to ref.null, so it is allowed):

  $ wax check ok.wax
