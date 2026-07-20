Wax type-checking verifies operand and result types that the Wasm validator
also checks.

A float-only method requires a floating-point receiver:

  $ wax check float-method-bad.wax
  Error: This operation cannot be applied to a value of type 'i64'.
   ──➤  float-method-bad.wax:1:28
  1 │ fn f() -> f32 { (0 as i64).ceil(); }
    ·                            ^^^^
  2 │ 
  [128]

An integer-only method requires an integer receiver:

  $ wax check int-method-bad.wax
  Error: This operation cannot be applied to a value of type 'f32'.
   ──➤  int-method-bad.wax:1:30
  1 │ fn f() -> i32 { (0.0 as f32).clz(); }
    ·                              ^^^
  2 │ 
  [128]

table.copy requires the source element type to fit the destination:

  $ wax check table-copy-bad.wax
  Error:
    The element type '&?extern' is not compatible with the expected element type
    '&?func'.
   ──➤  table-copy-bad.wax:3:10
  1 │ table t1: &?func [10];
  2 │ table t2: &?extern [10];
  3 │ fn f() { t1.copy(t2, 0 as i32, 1 as i32, 2 as i32); }
    ·          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │ 
  [128]

table.init requires the element segment's type to fit the table:

  $ wax check table-init-bad.wax
  Error:
    The element type '&?extern' is not compatible with the expected element type
    '&?func'.
   ──➤  table-init-bad.wax:3:10
  1 │ table t: &?func [10];
  2 │ elem el: &?extern = [];
  3 │ fn f() { t.init(el, 0 as i32, 1 as i32, 2 as i32); }
    ·          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │ 
  [128]

array.init_elem requires the element segment's type to fit the array:

  $ wax check array-init-elem-bad.wax
  Error:
    The element type '&?extern' is not compatible with the expected element type
    '&?func'.
   ──➤  array-init-elem-bad.wax:3:15
  1 │ type a = [mut &?func];
  2 │ elem e: &?extern = [];
  3 │ fn f(x: &a) { x.init(e, 0 as i32, 0 as i32, 0 as i32); }
    ·               ^
  4 │ 
  [128]

array.init names a data/element segment as its first argument; anything else
(here a `null`) is rejected rather than crashing the compiler:

  $ wax check array-init-nonsegment.wax
  Error: Invalid arguments in call to 'init'.
   ──➤  array-init-nonsegment.wax:2:15
  1 │ type a = [mut i8];
  2 │ fn f(x: &a) { x.init(null, 0 as i32, 0 as i32, 0 as i32); }
    ·               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  3 │ 
  [128]

array.new_elem likewise requires the element segment's type to fit the array:

  $ wax check array-new-elem-bad.wax
  Error:
    The element type '&?extern' is not compatible with the expected element type
    '&?func'.
   ──➤  array-new-elem-bad.wax:3:16
  1 │ type a = [mut &?func];
  2 │ elem e: &?extern = [];
  3 │ fn f() -> &a { [a | e @ 0 as i32; 0 as i32]; }
    ·                ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  4 │ 
  [128]

Reading a field that the struct type does not declare is rejected:

  $ wax check struct-get-unknown-field.wax
  Error: There is no field named 'y'.
   ──➤  struct-get-unknown-field.wax:2:24
  1 │ type s = { x: i32 };
  2 │ fn f(p: &s) -> i32 { p.y; }
    ·                        ^
  3 │ 
  [128]

An 'if' condition must be an i32, in both statement and expression position:

  $ wax check if-cond-not-i32.wax
  Error: This expression has type 'f64' but is expected to have type 'i32'.
   ──➤  if-cond-not-i32.wax:1:13
  1 │ fn f() { if 0.0 as f64 { } }
    ·             ^^^^^^^^^^
  2 │ 
  [128]

  $ wax check if-cond-not-i32-expr.wax
  Error: This expression has type 'f64' but is expected to have type 'i32'.
   ──➤  if-cond-not-i32-expr.wax:1:20
  1 │ fn f() -> i32 { if 0.0 as f64 => i32 { 0 as i32; } else { 1 as i32; } }
    ·                    ^^^^^^^^^^
  2 │ 
  [128]

An 'if' that produces a result must have an 'else' branch:

  $ wax check if-no-else.wax
  Error: This 'if' must produce a value and so requires an 'else' branch.
   ──➤  if-no-else.wax:1:17
  1 │ fn f() -> i32 { if 1 as i32 => i32 { 0 as i32; } }
    ·                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [128]

But an 'if' whose parameters already match its results may omit the else (the
empty else forwards them):

  $ wax check if-params-no-else.wax

A branch instruction needs at least its condition/reference operand; an operand
that yields no value (here a call to a function with no results) is reported
rather than crashing:

  $ wax check br-if-void-operand.wax
  Error: This instruction provides 0 value(s) but 1 was/were expected.
   ──➤  br-if-void-operand.wax:2:38
  1 │ fn g() { }
  2 │ fn f() { 'count: loop { br_if 'count g(); } }
    ·                                      ^^^
  3 │ 
  [128]

A throw argument must match the tag's parameter type; the caret points at the
offending argument, not the whole throw:

  $ wax check throw-arg-type.wax
  Error: This expression has type 'i64' but is expected to have type 'i32'.
   ──➤  throw-arg-type.wax:1:30
  1 │ tag t(i32); fn f() { throw t(5 as i64); }
    ·                              ^^^^^^^^
  2 │ 
  [128]

A branch or return operand whose type does not match the target underlines the
operand, not the whole branch/return:

  $ wax check return-operand-type.wax
  Error: This expression has type 'i64' but is expected to have type 'i32'.
   ──➤  return-operand-type.wax:1:24
  1 │ fn f() -> i32 { return 0 as i64; }
    ·                        ^^^^^^^^
  2 │ 
  [128]

  $ wax check br-operand-type.wax
  Error: This expression has type 'i64' but is expected to have type 'i32'.
   ──➤  br-operand-type.wax:1:27
  1 │ fn f() -> i32 'l: { br 'l 0 as i64; }
    ·                           ^^^^^^^^
  2 │ 
  [128]

A binary operator written as a method underlines the operator (the method
name):

  $ wax check binop-method-operands.wax
  Error: This operator cannot be applied to operands of types 'i64' and 'f64'.
   ──➤  binop-method-operands.wax:1:25
  1 │ fn f() { _ = (0 as i64).copysign(0 as f64); }
    ·                         ^^^^^^^^
  2 │ 
  [128]

In infix form the same error underlines the operator token itself:

  $ wax check binop-infix-operands.wax
  Error: This operator cannot be applied to operands of types 'i64' and 'f64'.
   ──➤  binop-infix-operands.wax:1:25
  1 │ fn f() { _ = (0 as i64) + (0 as f64); }
    ·                         ^
  2 │ 
  [128]

A unary operator applied to an operand of the wrong type underlines the
operator:

  $ wax check unop-operand.wax
  Error: This expression has type '&eq' but is expected to have type 'number'.
   ──➤  unop-operand.wax:1:21
  1 │ fn f(x: &eq) { _ = -x; }
    ·                     ^
  2 │ 
  [128]

A try_table catch routes the tag's values to a branch target; when they do not
match, the error names the tag/target mismatch and points at the target label:

  $ wax check catch-target-mismatch.wax
  Error:
    Catching this exception provides a value of type '&?t' but the handler's
    branch target expects '&t'.
   ──➤  catch-target-mismatch.wax:3:48
  1 │ type t = fn();
  2 │ tag e(&?t);
  3 │ fn f() -> &t { 'l: do &t { try {} catch [ e -> 'l] unreachable; } }
    ·                                                ^^
  4 │ 
  [128]

A memory/table management call whose argument form matches no known shape
(here `mem.fill` with one argument instead of three) names the method:

  $ wax check mem-mgmt-bad-args.wax
  Error: Invalid arguments in call to 'fill'.
   ──➤  mem-mgmt-bad-args.wax:2:10
  1 │ memory m: i32 [1];
  2 │ fn f() { m.fill(0 as i32); }
    ·          ^^^^^^^^^^^^^^^^
  3 │ 
  [128]

Matching element types and correct receivers pass:

  $ wax check ok.wax
