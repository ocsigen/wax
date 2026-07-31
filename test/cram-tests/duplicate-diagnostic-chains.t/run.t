A chained or nested construct anchors each level's type error at the shared
leftmost operand, so a broken operand must not report one identical diagnostic
per level. Each of these reports its error exactly once.

A cast chain — each `as` failing on the same `f32` operand:

  $ wax check -W dead-code=hidden -W unused-field=hidden --error-format short cast.wax
  cast.wax:2:23: error: This value of type 'f32' cannot be cast to the target type.
  [128]

A SIMD lane-op chain — the receiver of each `.extract_lane_*` is not a `v128`:

  $ wax check -W dead-code=hidden -W unused-field=hidden --error-format short simd.wax
  simd.wax:2:23: error: This expression has type 'i32' but is expected to have type 'v128'.
  [128]

A `br_table` in dead code carrying no value to two distinct value-expecting
targets:

  $ wax check -W dead-code=hidden -W unused-field=hidden --error-format short br_table.wax
  br_table.wax:4:41: error: This instruction provides 0 value(s) but 1 was/were expected.
  [128]

Chained calls on a value-less receiver (`m.init(..)` returns nothing):

  $ wax check -W dead-code=hidden -W unused-field=hidden --error-format short mem_init.wax
  mem_init.wax:5:5: error: An expression is expected here. This instruction returns 0 values.
  [128]

Chained calls whose ARGUMENTS are rejected, on a receiver the previous link
already poisoned: the failed call recovers with an `Error` value, and reporting
the same rejection again per link would repeat one `line:col: message`. Only the
innermost is reported; the unbound `m` in the argument list is its own error, at
its own span.

  $ wax check -W dead-code=hidden -W unused-field=hidden --error-format short mem_init_args.wax
  mem_init_args.wax:3:5: error: Invalid arguments in call to 'init'.
  mem_init_args.wax:3:38: error: The variable 'm' is not bound.
  [128]

A legacy `try`'s catch handler is a block of its own, and the tag's payload — the
handler entry pushes it — is pushed at the handler's span, not the `try`'s. A
payload the handler never consumes is therefore reported inside the handler; the
enclosing construct's own leftover keeps the `try`'s span, so the two are distinct
reports rather than one repeated line.

  $ wax check -W dead-code=hidden -W unused-field=hidden --error-format short try_payload.wax
  try_payload.wax:6:17: error: This value remains on the stack.
  try_payload.wax:3:5: error: This value remains on the stack.
  [128]

A type-test chain — `is` yields an `i32`, so the outer test gets a
non-reference operand of its own and, anchored at the same leftmost operand,
would report the identical error twice. A failed test poisons its result, as the
SIMD lane op does, so only the innermost is reported. Found by enumerating the
nesting shapes rather than by a fuzz run:

  $ wax check -W dead-code=hidden -W unused-field=hidden --error-format short test_chain.wax
  test_chain.wax:4:6: error: This expression has type 'i32' but is expected to have type '&?any'.
  [128]

A call whose callee is an arithmetic expression with an already-failed operand.
The failed call recovers with an `Error` value, but the binop arms deliberately
treat `Error` like `Unknown` — unifying it onto the other operand's type so the
operand cells still get a usable recovery type — which erased the poison and let
the outer call report "Expected function" a second time, at the chain's shared
start column. The binop now yields `Error` when either operand had already
failed, so the outer callee is absorbed silently, as it is for a failed call or
cast:

  $ wax check -W dead-code=hidden -W unused-field=hidden --error-format short call_binop.wax
  call_binop.wax:3:6: error: Expected function.
  [128]

A structured `try`'s catch arm is a block of its own, like a legacy `try`'s
handler. Anchoring its reports at the enclosing `try` made them collide with the
try body's: an arm that completes with nothing (an empty `t => {}`) reported the
missing value at the try's closing token, exactly where the body's own report
already sat, so the same line printed twice. Each now carries its own span — the
arm's braces, and the try's close:

  $ cat > try_arm.wax <<'WAX'
  > tag t();
  > #[export]
  > fn f(k: i32) -> i32 {
  >     try {
  >         _ = k;
  >     } catch {
  >         t => {}
  >     }
  > }
  > WAX
  $ wax check -W dead-code=hidden -W unused-field=hidden -W unused-result=hidden --error-format short try_arm.wax
  try_arm.wax:8:5: error: Expecting 1 returned value(s) from the stack, but there are 0.
  try_arm.wax:7:15: error: Expecting 1 returned value(s) from the stack, but there are 0.
  try_arm.wax:4:5: error: An expression is expected here. This instruction returns 0 values.
  [128]

An `if`'s two arms, like a `try`'s two arms above, each deliver the block's
result and each report their own failure to. An output underflow is anchored at
the block's CLOSING TOKEN, so arms sharing the `if`'s span rendered two distinct
reports — one per arm — as the same `line:col: message` twice (a fuzz DIAG_DUP,
mutant-3425.wax). Each arm carries its own span on both paths, the annotated one:

  $ cat > if_arm.wax <<'WAX'
  > fn f(x: i32) -> i32 {
  >     if x => i32 {
  >     } else {}
  > }
  > WAX
  $ wax check -W dead-code=hidden -W unused-field=hidden --error-format short if_arm.wax
  if_arm.wax:3:5: error: Expecting 1 returned value(s) from the stack, but there are 0.
  if_arm.wax:3:13: error: Expecting 1 returned value(s) from the stack, but there are 0.
  [128]

and the inferred one, where the result comes from the values reaching the exit
(here a `br` to the `if`'s own label from each arm, whose fall-through then
delivers nothing):

  $ cat > if_infer.wax <<'WAX'
  > fn f(x: i32) {
  >     _ = 'l: if x {
  >         if x { br 'l 5; }
  >     } else {
  >         if x { br 'l 6; }
  >     };
  > }
  > WAX
  $ wax check -W dead-code=hidden -W unused-field=hidden --error-format short if_infer.wax
  if_infer.wax:4:5: error: Expecting 1 returned value(s) from the stack, but there are 0.
  if_infer.wax:6:5: error: Expecting 1 returned value(s) from the stack, but there are 0.
  [128]
