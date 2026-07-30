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
