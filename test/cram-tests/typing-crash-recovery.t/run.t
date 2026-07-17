Recoverable user errors that used to crash the type checker (exit 125) or hang
it, instead of being rejected cleanly (exit 128). Each of these reaches a
recovery path in the typer; the fixes keep that path from tripping an assertion,
an uncaught exception, or a non-terminating subtype query.

A self/forward in-group supertype is reported as unbound and the offending
supertype is then dropped, so the normalized subtype stays acyclic and later
subtype queries terminate (it used to loop forever):

  $ cat > cycle.wax <<'WAX'
  > type t: t = { x: i32 };
  > type u = { x: i64 };
  > fn f(a: &t) -> &u { a; }
  > WAX

  $ wax check cycle.wax
  Error: The type 't' is not bound.
   ──➤  cycle.wax:1:9
  1 │ type t: t = { x: i32 };
    ·         ^
  2 │ type u = { x: i64 };
  3 │ fn f(a: &t) -> &u { a; }
  Error: Expecting type '&u' but got type '&t'.
   ──➤  cycle.wax:3:21
  1 │ type t: t = { x: i32 };
  2 │ type u = { x: i64 };
  3 │ fn f(a: &t) -> &u { a; }
    ·                     ^
  4 │ 
  [128]

A struct literal that omits a declared field and contains a hole no longer
raises [Not_found] in the hole-order pass:

  $ cat > missing-field-hole.wax <<'WAX'
  > type point = { x: i32, y: i32 };
  > fn f() { 1; let p: &point = {point| x: _}; }
  > WAX

  $ wax check missing-field-hole.wax
  Error: This structure provides 1 field(s) but 2 was/were expected.
   ──➤  missing-field-hole.wax:2:29
  1 │ type point = { x: i32, y: i32 };
  2 │ fn f() { 1; let p: &point = {point| x: _}; }
    ·                             ^^^^^^^^^^^^^
  3 │ 
  Error: There is no field named 'y'.
   ──➤  missing-field-hole.wax:2:29
  1 │ type point = { x: i32, y: i32 };
  2 │ fn f() { 1; let p: &point = {point| x: _}; }
    ·                             ^^^^^^^^^^^^^
  3 │ 
  Warning: The local variable 'p' is never used.
   ──➤  missing-field-hole.wax:2:17
  1 │ type point = { x: i32, y: i32 };
  2 │ fn f() { 1; let p: &point = {point| x: _}; }
    ·                 ^
  3 │ 
  [128]

A [match] with a hole scrutinee is rejected with a clear diagnostic rather than
the old empty-stack cascade: the scrutinee is evaluated inside the lowering's
blocks, where the enclosing statement's pending stack values are out of reach, so
a hole there has nothing to consume. (The trailing value is then genuinely
unconsumed, hence the second error.)

  $ cat > match-hole.wax <<'WAX'
  > type t = { x: i32 };
  > fn f(a: &any) { a; match _ { p: &t => {} _ => {} } }
  > WAX

  $ wax check match-hole.wax
  Error: A hole '_' cannot be used as a 'match' scrutinee.
   ──➤  match-hole.wax:2:26
  1 │ type t = { x: i32 };
  2 │ fn f(a: &any) { a; match _ { p: &t => {} _ => {} } }
    ·                          ^
  3 │ 
  Error: This value remains on the stack.
   ──➤  match-hole.wax:2:17
  1 │ type t = { x: i32 };
  2 │ fn f(a: &any) { a; match _ { p: &t => {} _ => {} } }
    ·                 ^
  3 │ 
  Warning: The local variable 'p' is never used.
   ──➤  match-hole.wax:2:30
  1 │ type t = { x: i32 };
  2 │ fn f(a: &any) { a; match _ { p: &t => {} _ => {} } }
    ·                              ^
  3 │ 
  [128]

An unbound name in an erroneous [match] scrutinee is reported exactly once (it
used to be reported twice, since the scrutinee was typed both standalone and
again inside the lowering):

  $ cat > match-unbound.wax <<'WAX'
  > type t = { x: i32 };
  > fn f() { match undefined_var { p: &t => {} _ => {} } }
  > WAX

  $ wax check match-unbound.wax 2>&1 | grep -c "is not bound"
  1

A struct literal with an extra (undeclared) field containing a hole no longer
leaves that hole unconsumed (which tripped [assert (args = [])]); the extra field
is typed for recovery and its hole participates in the ordering check:

  $ cat > extra-field-hole.wax <<'WAX'
  > type p = { a: i32 };
  > const g: &p = { a: 1, zzz: _ };
  > WAX

  $ wax check extra-field-hole.wax
  Error: The stack is empty.
   ──➤  extra-field-hole.wax:2:15
  1 │ type p = { a: i32 };
  2 │ const g: &p = { a: 1, zzz: _ };
    ·               ^^^^^^^^^^^^^^^^
  3 │ 
  Error: This structure provides 2 field(s) but 1 was/were expected.
   ──➤  extra-field-hole.wax:2:15
  1 │ type p = { a: i32 };
  2 │ const g: &p = { a: 1, zzz: _ };
    ·               ^^^^^^^^^^^^^^^^
  3 │ 
  Error: This expression occurs before a hole '_'.
   ──➤  extra-field-hole.wax:2:20
  1 │ type p = { a: i32 };
  2 │ const g: &p = { a: 1, zzz: _ };
    ·                    ^
  3 │ 
  Error: Only constant expressions are allowed here.
   ──➤  extra-field-hole.wax:2:28
  1 │ type p = { a: i32 };
  2 │ const g: &p = { a: 1, zzz: _ };
    ·                            ^
  3 │ 
  [128]

An extra field with an unbound name is likewise reported (it used to be silently
swallowed):

  $ cat > extra-field-unbound.wax <<'WAX'
  > type p = { a: i32 };
  > const g: &p = { a: 1, zzz: undefined_name };
  > WAX

  $ wax check extra-field-unbound.wax 2>&1 | grep -c "is not bound"
  1

A supertype that is a forward or self reference is invalid (the spec requires a
supertype to be declared before), so it is dropped and reported; using such a
type in a `match` no longer hangs the subtype walk (it used to loop over the
cyclic supertype chain):

  $ cat > super-cycle.wax <<'WAX'
  > type t: t = { x: i32 };
  > fn f(a: &any) -> i32 { match a { p: &t => { return 0; } _ => { return -1; } } }
  > WAX

  $ wax check super-cycle.wax 2>&1 | grep -c "is not bound"
  1

A struct literal with a hole under such an erroneous type no longer crashes: the
unconsumed hole operand left by the aborted recovery is tolerated rather than
tripping an assertion:

  $ cat > super-cycle-hole.wax <<'WAX'
  > type t: u = { x: i32 };
  > type u = { x: i32 };
  > fn f() { {t| x: _ }; }
  > WAX

  $ wax check super-cycle-hole.wax >/dev/null 2>&1; echo $?
  128
