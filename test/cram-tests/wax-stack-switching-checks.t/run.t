Wax type-checking performs the structural stack-switching checks that the Wasm
validator does, rather than deferring them to the compiled module.

A continuation type must wrap a function type:

  $ wax check cont-not-func.wax
  Error: Expected function type.
   ──➤  cont-not-func.wax:1:16
  1 │ type ct = cont ct;
    ·                ^^
  2 │ 
  [128]

A cast to a continuation type is a compile-time ascription: continuations
carry no RTT, so it is accepted exactly when it lowers to no instruction — an
identity or upcast (letting a resume go through a supertype signature, which
selects that supertype's type immediate), a null literal with a nullable
target, or a stack-polymorphic operand the ascription pins. No ref.cast is
ever emitted, and no redundant-cast lint fires on the "redundant" upcast (it
is the intended use):

  $ wax --validate ascription.wax -f wat
  (type $ft0 (sub (func (param i32) (result i32))))
  (type $k0 (sub (cont $ft0)))
  (type $ft1 (sub final $ft0 (func (param i32) (result i32))))
  (type $k1 (sub final $k0 (cont $ft1)))
  
  ;; upcast: the resume goes through the supertype signature (resume $k0)
  (func $upcast (param $c (ref $k1)) (param $x i32) (result i32)
    (resume $k0 (local.get $x) (local.get $c))
  )
  
  ;; identity ascription
  (func $identity (param $c (ref $k0)) (param $x i32) (result i32)
    (resume $k0 (local.get $x) (local.get $c))
  )
  
  ;; a null literal cast to a nullable continuation target (ref.null)
  (func $nullc (result (ref null $k0)) (ref.null $k0))
  
  ;; a stack-polymorphic operand: the ascription pins the type
  (func $dead (unreachable) (drop))

A genuine downcast stays rejected — no cast can ever fix it, so the hint
points at the value's introduction:

  $ wax check cast-cont.wax
  Error:
    A cast to a continuation type is a compile-time ascription: the operand's
    type must already be a subtype of the target, as there is no runtime
    continuation cast.
   ──➤  cast-cont.wax:3:27
  1 │ type ft = fn() -> i32;
  2 │ type k = cont ft;
  3 │ fn f(c: &?cont) -> i32 { (c as &k).resume(); }
    ·                           ^^^^^^^
  4 │ 
  Hint:
    Give the value a declared continuation type where it is introduced (a
    parameter, local or block-result annotation).
  [128]

ref.test (is) and br_on_cast/br_on_cast_fail are inherently runtime tests, so
a continuation target stays rejected there unconditionally:

  $ wax check test-cont.wax
  Error: Continuation types cannot be used in a cast instruction.
   ──➤  test-cont.wax:1:27
  1 │ fn f() { unreachable; _ = _ is &?cont; }
    ·                           ^^^^^^^^^^^
  2 │ 
  [128]

  $ wax check br-on-cast-cont.wax
  Error: Continuation types cannot be used in a cast instruction.
   ──➤  br-on-cast-cont.wax:1:43
  1 │ fn f() { _ = 'l: do &?cont { unreachable; br_on_cast 'l &?cont _; }; }
    ·                                           ^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [128]

A resume handler label must receive the tag's parameters followed by a
continuation of the remaining result type:

  $ wax check resume-handler.wax
  Error:
    Type mismatch in this stack switching instruction: this handler must take
    the tag's parameters followed by a continuation of the remaining result
    type.
   ──➤  resume-handler.wax:7:48
  5 │     _ =
  6 │         'on_foo: do &ft {
  7 │             (null as &?ct).resume() on [foo -> 'on_foo];
    ·                                                ^^^^^^^
  8 │             unreachable;
  9 │         };
  [128]

A cont.bind's destination continuation must match the source with its leading
parameters bound away:

  $ wax check cont-bind-mismatch.wax
  Error:
    Type mismatch in this stack switching instruction: the bound parameters and
    results do not match between the two continuation types.
   ──➤  cont-bind-mismatch.wax:5:25
  3 │ type ft1_alt = fn(i64) -> i32;
  4 │ type ct1_alt = cont ft1_alt;
  5 │ fn error(p: &ct2) { _ = ct1_alt::bind(123 as i64, p); }
    ·                         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  6 │ 
  [128]

A switch's continuation must have a continuation type as its last parameter (it
names the continuation being switched to):

  $ wax check switch-last-param-not-cont.wax
  Error:
    Type mismatch in this stack switching instruction: the continuation's last
    parameter must itself be a continuation type.
   ──➤  switch-last-param-not-cont.wax:4:19
  2 │ type ct1 = cont ft1;
  3 │ tag e();
  4 │ fn sw(k: &?ct1) { k.switch(tag: e); }
    ·                   ^^^^^^^^^^^^^^^^
  5 │ 
  [128]

A switch tag must take no parameters and its results must match both
continuation types:

  $ wax check switch-tag-has-param.wax
  Error:
    Type mismatch in this stack switching instruction: the 'switch' tag must
    take no parameters and its results must match the two continuation types.
   ──➤  switch-tag-has-param.wax:8:26
  6 │ }
  7 │ tag e(i32) -> i32;
  8 │ fn sw(k: &?ct1) -> i32 { k.switch(tag: e); }
    ·                          ^^^^^^^^^^^^^^^^
  9 │ 
  [128]

A repeated `tag:` immediate is reported at the second one, pointing back at the
first:

  $ wax check switch-dup-tag.wax
  Error: The argument label 'tag' is given several times.
   ──➤  switch-dup-tag.wax:8:48
  6 │ }
  7 │ tag e() -> i32;
  8 │ fn sw(k: &?ct1) -> i32 { k.switch(tag: e, tag: e); }
    ·                                                ^
    ·                                        ^ previously given here
  9 │ 
  [128]

Well-formed stack-switching code passes (a null cast to a nullable continuation
reference lowers to ref.null, so it is allowed; a switch whose continuation's
last parameter is itself a continuation type validates):

  $ wax check ok.wax

The method / constructor surface has its own checks: the `on` clause is only
accepted on the resume family; an abstract `&cont` receiver cannot supply the
type immediate (and there is no cast into a continuation type); `switch`
requires its labelled `tag:` immediate; `resume_throw` takes its tag
call-style; and the `T::` constructor namespace knows only `new` and `bind`,
at their arities. Operand counts follow from the inferred types.

  $ wax check surface-errors.wax
  Error:
    An 'on' handler clause is only allowed on a 'resume', 'resume_throw' or
    'resume_throw_ref' call.
   ──➤  surface-errors.wax:7:28
  5 │ 
  6 │ // an `on` clause is only accepted on the resume family
  7 │ fn bad_on(x: i32) -> i32 { (x + 1) on [t -> switch]; }
    ·                            ^^^^^^^^^^^^^^^^^^^^^^^^
  8 │ 
  9 │ // the receiver's declared continuation type is the type immediate; an
  Error:
    The continuation type cannot be resolved from this expression. Give the
    value a declared continuation type where it is introduced (a parameter,
    local or block-result annotation): a continuation reference cannot be
    narrowed by a cast.
    ──➤  surface-errors.wax:11:38
   9 │ // the receiver's declared continuation type is the type immediate; an
  10 │ // abstract &cont cannot supply it (and cannot be cast into one)
  11 │ fn abstract_recv(c: &?cont) -> i32 { c.resume(); }
     ·                                      ^
  12 │ 
  13 │ // switch requires its enabling tag as a labelled immediate
  Error:
    A 'switch' names its enabling tag as a labelled immediate, e.g.
    'c.switch(x, tag: t)'.
    ──➤  surface-errors.wax:14:29
  12 │ 
  13 │ // switch requires its enabling tag as a labelled immediate
  14 │ fn no_tag(c: &k) -> i32 { c.switch(); }
     ·                             ^^^^^^
  15 │ 
  16 │ // resume_throw takes its tag call-style, grouping the payload with the tag
  Error:
    'resume_throw' raises a tag applied to its payload, e.g.
    'c.resume_throw(exc(x))'.
    ──➤  surface-errors.wax:17:40
  15 │ 
  16 │ // resume_throw takes its tag call-style, grouping the payload with the tag
  17 │ fn bad_throw(c: &k, x: i32) -> i32 { c.resume_throw(x); }
     ·                                        ^^^^^^^^^^^^
  18 │ 
  19 │ // T:: members exist only on continuation types, and only new/bind
  Error: There is no 'k::renew' intrinsic.
    ──➤  surface-errors.wax:20:34
  18 │ 
  19 │ // T:: members exist only on continuation types, and only new/bind
  20 │ fn unknown_member(c: &k) -> &k { k::renew(c); }
     ·                                  ^^^^^^^^
  21 │ 
  22 │ // arity of the constructors is checked
  Error: This instruction expects 1 operand(s) but 0 was/were provided.
    ──➤  surface-errors.wax:23:26
  21 │ 
  22 │ // arity of the constructors is checked
  23 │ fn wrong_arity() -> &k { k::new(); }
     ·                          ^^^^^^
  24 │ 
  25 │ // the operand count follows from the inferred types
  Error: This instruction expects 1 operand(s) but 2 was/were provided.
    ──➤  surface-errors.wax:26:32
  24 │ 
  25 │ // the operand count follows from the inferred types
  26 │ fn missing_arg(c: &k) -> i32 { c.resume(1); }
     ·                                ^^^^^^^^^^^
  27 │ 
  [128]

`T::` extends to declared types, making the `::` namespace shared with the
built-in type names, so a `type` (or `rec` member) may not take one:

  $ wax check reserved.wax
  Error: 'i64' is a reserved built-in type name.
   ──➤  reserved.wax:3:6
  1 │ // extending T:: to declared types makes the :: namespace shared with the
  2 │ // built-in type names, so those are reserved
  3 │ type i64 = [i8];
    ·      ^^^
  4 │ type any = { x: i32 };
  5 │ type atomic = [mut i32];
  Error: 'any' is a reserved built-in type name.
   ──➤  reserved.wax:4:6
  2 │ // built-in type names, so those are reserved
  3 │ type i64 = [i8];
  4 │ type any = { x: i32 };
    ·      ^^^
  5 │ type atomic = [mut i32];
  6 │ rec { type func = fn(); type k = cont func; }
  Error: 'atomic' is a reserved built-in type name.
   ──➤  reserved.wax:5:6
  3 │ type i64 = [i8];
  4 │ type any = { x: i32 };
  5 │ type atomic = [mut i32];
    ·      ^^^^^^
  6 │ rec { type func = fn(); type k = cont func; }
  7 │ 
  Error: 'func' is a reserved built-in type name.
   ──➤  reserved.wax:6:12
  4 │ type any = { x: i32 };
  5 │ type atomic = [mut i32];
  6 │ rec { type func = fn(); type k = cont func; }
    ·            ^^^^
  7 │ 
  [128]
