Diagnostics-quality fixes in the Wax typer: false positives, false negatives,
cascades and wrong spans, each mirroring the Wasm validator's behaviour.

The `precedence` lint scans past comments (line and block) when checking whether
an operand is already parenthesised, so a comment next to the bracket no longer
produces a spurious warning suggesting parentheses that are already there:

  $ cat > precedence.wax <<'WAX'
  > fn f(n: i32) -> i32 { 1 << (/*c*/ n - 1); }
  > fn g(n: i32) -> i32 { (n - 1 /*c*/) << 2; }
  > WAX

  $ wax check -W precedence=warning precedence.wax

A genuinely unparenthesised confusing mix still warns:

  $ cat > precedence-bad.wax <<'WAX'
  > fn f(n: i32) -> i32 { 1 << n - 1; }
  > WAX

  $ wax check -W precedence=warning precedence-bad.wax
  Warning [precedence]: Operator precedence here is easy to misread.
   ──➤  precedence-bad.wax:1:25
  1 │ fn f(n: i32) -> i32 { 1 << n - 1; }
    ·                         ^^
    ·                              ^ This arithmetic operator binds tighter than the shift operator.
  2 │ 
  Hint: Add parentheses to make the grouping explicit.

`shift-count-overflow` fires on a flexible integer literal once context pins its
width, matching the Wasm side: `1 << 40` typed `i32` overflows, typed `i64` does
not; and an unsigned count past `2^63` (which a signed parse would read as
negative) is caught and printed unsigned:

  $ cat > shift.wax <<'WAX'
  > fn i32ctx() -> i32 { 1 << 40; }
  > fn i64ctx() -> i64 { 1 << 40; }
  > fn hex(x: i64) -> i64 { x << 0xFFFF_FFFF_FFFF_FFFF; }
  > WAX

  $ wax check -W shift-count-overflow=warning shift.wax
  Warning [shift-count-overflow]:
    The shift count 40 is at least the operand width (32 bits).
   ──➤  shift.wax:1:24
  1 │ fn i32ctx() -> i32 { 1 << 40; }
    ·                        ^^
  2 │ fn i64ctx() -> i64 { 1 << 40; }
  3 │ fn hex(x: i64) -> i64 { x << 0xFFFF_FFFF_FFFF_FFFF; }
  Hint: Wasm masks the count modulo 32, shifting by 8 instead.
  Warning [shift-count-overflow]:
    The shift count 18446744073709551615 is at least the operand width (64
    bits).
   ──➤  shift.wax:3:27
  1 │ fn i32ctx() -> i32 { 1 << 40; }
  2 │ fn i64ctx() -> i64 { 1 << 40; }
  3 │ fn hex(x: i64) -> i64 { x << 0xFFFF_FFFF_FFFF_FFFF; }
    ·                           ^^
  4 │ 
  Hint: Wasm masks the count modulo 64, shifting by 63 instead.

The Wasm validator mirrors the unsigned-count fix, so the same shift flagged in
WAT form reads its count unsigned too (the fuzzer's lint-parity oracle relies on
the two sides agreeing):

  $ cat > shift.wat <<'WAT'
  > (module (func (param i64) (result i64)
  >   (i64.shl (local.get 0) (i64.const 0xFFFF_FFFF_FFFF_FFFF))))
  > WAT

  $ wax check -W shift-count-overflow=warning shift.wat
  Warning [shift-count-overflow]:
    The shift count 18446744073709551615 is at least the operand width (64
    bits).
   ──➤  shift.wat:2:4
  1 │ (module (func (param i64) (result i64)
  2 │   (i64.shl (local.get 0) (i64.const 0xFFFF_FFFF_FFFF_FFFF))))
    ·    ^^^^^^^
  3 │ 
  Hint: Wasm masks the count modulo 64, shifting by 63 instead.

An arity error on a memory access no longer drags in a bogus memarg diagnostic
on the surplus argument (it used to read a non-literal extra as an immediate):

  $ cat > memarg.wax <<'WAX'
  > memory mem0: i32 [1];
  > fn f(p: i32, q: i32) -> i32 { mem0.load32(p, q); }
  > WAX

  $ wax check memarg.wax
  Error: This instruction expects 1 operand(s) but 2 was/were provided.
   ──➤  memarg.wax:2:31
  1 │ memory mem0: i32 [1];
  2 │ fn f(p: i32, q: i32) -> i32 { mem0.load32(p, q); }
    ·                               ^^^^^^^^^^^^^^^^^
  3 │ 
  [128]

`null == null` is accepted: it compiles to `ref.eq` on two bottom references:

  $ cat > nulleq.wax <<'WAX'
  > fn f() -> i32 { null == null; }
  > WAX

  $ wax -f wat nulleq.wax
  (func $f (result i32) (ref.eq (ref.null none) (ref.null none)))

An `is` test underlines the whole expression, not just the operand:

  $ cat > istest.wax <<'WAX'
  > type ft = fn() -> i32;
  > type k = cont ft;
  > fn f(c: &k) -> i32 { (c is &k); }
  > WAX

  $ wax check istest.wax
  Error: Continuation types cannot be used in a cast instruction.
   ──➤  istest.wax:3:23
  1 │ type ft = fn() -> i32;
  2 │ type k = cont ft;
  3 │ fn f(c: &k) -> i32 { (c is &k); }
    ·                       ^^^^^^^
  4 │ 
  [128]

An unbound resume-handler label is reported once, without a second
stack-switching contract error piled on the same label:

  $ cat > resume.wax <<'WAX'
  > type ft = fn() -> i32;
  > type k = cont ft;
  > tag yield() -> i32;
  > fn f(c: &k) -> i32 { c.resume() on [yield -> 'nosuch]; }
  > WAX

  $ wax check resume.wax
  Error: The label 'nosuch' is not bound.
   ──➤  resume.wax:4:46
  2 │ type k = cont ft;
  3 │ tag yield() -> i32;
  4 │ fn f(c: &k) -> i32 { c.resume() on [yield -> 'nosuch]; }
    ·                                              ^^^^^^^
  5 │ 
  [128]

`eager-select` descends into an `on`-clause (which only wraps a resume-family
call, itself a hazard), so a resume in a `?:` branch is flagged:

  $ cat > eager.wax <<'WAX'
  > type ft = fn() -> i32;
  > type k = cont ft;
  > fn f(cond: i32, c: &k, fb: i32) -> i32 { cond ? (c.resume() on []) : fb; }
  > WAX

  $ wax check -W eager-select=warning eager.wax
  Warning [eager-select]:
    This operation is evaluated even when the condition selects the other
    branch.
   ──➤  eager.wax:3:50
  1 │ type ft = fn() -> i32;
  2 │ type k = cont ft;
  3 │ fn f(cond: i32, c: &k, fb: i32) -> i32 { cond ? (c.resume() on []) : fb; }
    ·                                                  ^^^^^^^^^^
    ·                                          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ This '?:' evaluates both branches (it compiles to a 'select').
  4 │ 
  Hint: Use an 'if' expression to evaluate only the chosen branch.

An operand-count error on a method, intrinsic, throw or indirect call
underlines the callee (the tag name, the receiver.method part, or the callee
expression), not the whole call with its arguments:

  $ cat > arity.wax <<'WAX'
  > tag exc(i32);
  > fn f() { throw exc(1, 2); }
  > type arr = [mut i32];
  > fn g(a: &arr) { a.fill(); }
  > fn h(x: f32) -> f32 { x.min(); }
  > fn v(v: v128) -> i32 { v.extract_lane_i32x4(); }
  > type F = fn(i32);
  > fn k(c: &F) { c(); }
  > WAX

  $ wax check arity.wax
  Error: This instruction expects 1 operand(s) but 2 was/were provided.
   ──➤  arity.wax:2:16
  1 │ tag exc(i32);
  2 │ fn f() { throw exc(1, 2); }
    ·                ^^^
  3 │ type arr = [mut i32];
  4 │ fn g(a: &arr) { a.fill(); }
  Error: This instruction expects 3 operand(s) but 0 was/were provided.
   ──➤  arity.wax:4:17
  2 │ fn f() { throw exc(1, 2); }
  3 │ type arr = [mut i32];
  4 │ fn g(a: &arr) { a.fill(); }
    ·                 ^^^^^^
  5 │ fn h(x: f32) -> f32 { x.min(); }
  6 │ fn v(v: v128) -> i32 { v.extract_lane_i32x4(); }
  Error: This instruction expects 1 operand(s) but 0 was/were provided.
   ──➤  arity.wax:5:23
  3 │ type arr = [mut i32];
  4 │ fn g(a: &arr) { a.fill(); }
  5 │ fn h(x: f32) -> f32 { x.min(); }
    ·                       ^^^^^
  6 │ fn v(v: v128) -> i32 { v.extract_lane_i32x4(); }
  7 │ type F = fn(i32);
  Error: This instruction expects 1 operand(s) but 0 was/were provided.
   ──➤  arity.wax:6:24
  4 │ fn g(a: &arr) { a.fill(); }
  5 │ fn h(x: f32) -> f32 { x.min(); }
  6 │ fn v(v: v128) -> i32 { v.extract_lane_i32x4(); }
    ·                        ^^^^^^^^^^^^^^^^^^^^
  7 │ type F = fn(i32);
  8 │ fn k(c: &F) { c(); }
  Error: This instruction expects 1 operand(s) but 0 was/were provided.
   ──➤  arity.wax:8:15
  6 │ fn v(v: v128) -> i32 { v.extract_lane_i32x4(); }
  7 │ type F = fn(i32);
  8 │ fn k(c: &F) { c(); }
    ·               ^
  9 │ 
  [128]

A br_table whose targets take different numbers of values is anchored at the
mismatching label, pointing back at the other target:

  $ cat > brt.wax <<'WAX'
  > fn f(x: i32) -> i32 {
  >     'a: do i32 {
  >         'b: do {
  >             1;
  >             br_table ['b, else 'a] x;
  >         }
  >         2;
  >     };
  > }
  > WAX

  $ wax check brt.wax
  Error:
    This branch target expects 1 value(s), while branch target 'b' expects 0
    value(s).
   ──➤  brt.wax:5:32
  3 │         'b: do {
  4 │             1;
  5 │             br_table ['b, else 'a] x;
    ·                                ^^
    ·                       ^^ other branch target here
  6 │         }
  7 │         2;
  [128]
