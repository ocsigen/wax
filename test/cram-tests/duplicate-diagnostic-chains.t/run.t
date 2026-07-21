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
