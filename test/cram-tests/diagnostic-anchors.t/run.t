Same-location duplicate diagnostics: a single construct must not report the
same located line twice. Three classes used to (fuzz oracle 2b, DIAG_DUP):
per-arm `if` stack-shape errors anchored at the whole `if`, per-operand
`select` errors anchored at the `select`, and `br_table` re-checking a
repeated target once per occurrence.

An `if` whose arms both fail anchors each report at the arm, not the `if`, so
the two reports are distinct and point at the offending arm.

  $ cat > if-arms.wat <<'WAT'
  > (module
  >   (func (result i32)
  >     (i32.const 1)
  >     (if (result i32)
  >       (then)
  >       (else))))
  > WAT
  $ wax check --error-format short if-arms.wat
  if-arms.wat:5:7: error: Type mismatch: the stack is empty (a value is missing).
  if-arms.wat:6:8: error: Type mismatch: the stack is empty (a value is missing).
  [128]

The same module in binary form: the decoder gives each arm its byte-offset
span, so the two reports stay distinct there too (they were both anchored at
the `if` opcode's offset before).

  $ wax check --error-format short if-empty-arms.wasm
  if-empty-arms.wasm:1:29: error: Type mismatch: the stack is empty (a value is missing).
  if-empty-arms.wasm:1:30: error: Type mismatch: the stack is empty (a value is missing).
  [128]

A bare `select` on two reference operands reports each operand at its own
push location (with the value-producer wording), not both at the `select`.

  $ cat > select-refs.wat <<'WAT'
  > (module
  >   (type $t (struct))
  >   (func (param $r (ref $t))
  >     (local.get $r)
  >     (local.get $r)
  >     (i32.const 1)
  >     (select)
  >     (drop)))
  > WAT
  $ wax check --error-format short select-refs.wat
  select-refs.wat:5:6: error: Type mismatch: this produces a value of type '(ref $t)', but a numeric or vector type is expected.
  select-refs.wat:4:6: error: Type mismatch: this produces a value of type '(ref $t)', but a numeric or vector type is expected.
  [128]

A `br_table` target repeated in the list — by depth or by a label name
resolving to that same depth — is checked and reported once.

  $ cat > br-table-repeat.wat <<'WAT'
  > (module
  >   (func (result i32)
  >     (block $l (result i32)
  >       (i64.const 1)
  >       (i32.const 0)
  >       (br_table $l 0 0))))
  > WAT
  $ wax check --error-format short br-table-repeat.wat
  br-table-repeat.wat:4:8: error: Type mismatch: this produces a value of type 'i64', but type 'i32' is expected.
  [128]

Two DISTINCT mismatching targets still get one report each.

  $ cat > br-table-two.wat <<'WAT'
  > (module
  >   (func (result i32)
  >     (block $a (result i32)
  >       (block $b (result i32)
  >         (i64.const 1)
  >         (i32.const 0)
  >         (br_table $b $a)))))
  > WAT
  $ wax check --error-format short br-table-two.wat
  br-table-two.wat:5:10: error: Type mismatch: this produces a value of type 'i64', but type 'i32' is expected.
  br-table-two.wat:5:10: error: Type mismatch: this produces a value of type 'i64', but type 'i32' is expected.
  [128]

Lint parity for a type test on a bottom-typed operand: the Wax typer lints it
like the Wasm validator does (only a bottom operand's CAST is exempt — its
removal edit would be load-bearing). The always-false flavor is not
expressible: a cross-hierarchy `is` is a type error on both sides.

  $ cat > bottom-test.wax <<'WAX'
  > type s = open { };
  > fn f() -> i32 {
  >     null as &?none is &?s;
  > }
  > fn g(x: &none) -> i32 {
  >     x is &?s;
  > }
  > WAX
  $ wax check -W redundant-operation=warning --error-format short bottom-test.wax
  bottom-test.wax:3:5: warning: This type test is always true: the value already has this type. [redundant-operation]
  bottom-test.wax:6:5: warning: This type test is always true: the value already has this type. [redundant-operation]

  $ cat > bottom-test.wat <<'WAT'
  > (module
  >   (type $s (sub (struct)))
  >   (func (result i32) (ref.test (ref null $s) (ref.null none))))
  > WAT
  $ wax check -W redundant-operation=warning --error-format short bottom-test.wat
  bottom-test.wat:3:23: warning: This type test is always true: the value already has this type. [redundant-operation]

The Wax typer's own same-location duplicate classes (surfaced by the wax-side
fault-locality/DIAG_DUP oracles). A compound assignment to an unbound name
reports it once (the desugared read), not once per read+write.

  $ cat > compound-unbound.wax <<'WAX'
  > fn f() {
  >     nope += 1;
  > }
  > WAX
  $ wax check --error-format short compound-unbound.wax
  compound-unbound.wax:2:5: error: The variable 'nope' is not bound.
  [128]

A non-literal lane of a constant-position SIMD construction is reported once
(by the intrinsic's typing), not re-reported by the constant-expression walk.

  $ cat > simd-lane.wax <<'WAX'
  > fn h() -> i32 { 1; }
  > let gl: v128 = v128::i8x16(1,2,3,4,5,6,7, h(), 9,10,11,12,13,14,15,16);
  > WAX
  $ wax check --error-format short simd-lane.wax
  simd-lane.wax:2:43: error: Only constant expressions are allowed here.
  [128]

A stack underflow is reported once, not once per remaining pop (the underflow
turns the stack unreachable, as in the Wasm validator).

  $ cat > holes.wax <<'WAX'
  > fn f() -> v128 {
  >     v128::i8x16(1, 0, 0, 0, _, 0, 0, 8, 1, 0, 0, _, 0, 0, 0, 8);
  > }
  > WAX
  $ wax check --error-format short holes.wax
  holes.wax:2:5: error: Expecting 2 value(s) from the stack, but there are 0.
  holes.wax:2:17: error: This expression occurs before a hole '_'.
  holes.wax:2:29: error: Only constant expressions are allowed here.
  holes.wax:2:50: error: Only constant expressions are allowed here.
  [128]

Calling a zero-value expression reports "an expression is expected" once, not
once per query of the callee's type.

  $ cat > void-callee.wax <<'WAX'
  > fn v() { }
  > fn f() -> i32 {
  >     v()(1, 2);
  >     3;
  > }
  > WAX
  $ wax check --error-format short void-callee.wax
  void-callee.wax:3:5: error: An expression is expected here. This instruction returns 0 values.
  [128]
