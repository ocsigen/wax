A hole is rejected as the scrutinee of a [match], the index of a [dispatch] or
the condition of a [while]: each desugars to a nested block structure, and a hole
inside a block draws only from that block's own stack, not from the values
pending in the enclosing sequence. The rejection is a single clear diagnostic
(the trailing value is then genuinely unconsumed, hence the second error).

  $ cat > match-scrut.wax <<'WAX'
  > type t = { x: i32 };
  > fn f(a: &any) { a; match _ { p: &t => {} _ => {} } }
  > WAX

  $ wax check match-scrut.wax 2>&1 | grep -A1 "cannot be used"
  Error: A hole '_' cannot be used as a 'match' scrutinee.
   ──➤  match-scrut.wax:2:26

  $ cat > while-cond.wax <<'WAX'
  > fn f() { 1; while _ { } }
  > WAX

  $ wax check while-cond.wax 2>&1 | grep -A1 "cannot be used"
  Error: A hole '_' cannot be used as a 'while' condition.
   ──➤  while-cond.wax:1:19

A hole nested inside the operand — not just a bare `_` — is rejected too:

  $ cat > while-nested.wax <<'WAX'
  > fn f() { 1; while _ != 0 { } }
  > WAX

  $ wax check while-nested.wax 2>&1 | grep -c "cannot be used as a 'while' condition"
  1

A scrutinee that is a real value (rather than a hole) is of course fine:

  $ cat > scrut-ok.wax <<'WAX'
  > type t = { x: i32 };
  > fn f(a: &any) { match a { p: &t => {} _ => {} } }
  > WAX

  $ wax check scrut-ok.wax
  Warning [unused-local]: The local variable 'p' is never used.
   ──➤  scrut-ok.wax:2:27
  1 │ type t = { x: i32 };
  2 │ fn f(a: &any) { match a { p: &t => {} _ => {} } }
    ·                           ^
  3 │ 
