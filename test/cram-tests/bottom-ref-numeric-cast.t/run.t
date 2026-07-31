A hole in dead code stands for a value off the polymorphic bottom, and `_!` makes
it the BOTTOM NON-NULL REFERENCE — a subtype of every reference type, of no
numeric one. A plain (unsigned) cast of it to a numeric type is therefore
rejected, exactly as for a concrete reference: `&?i31 as f32` has no lowering.

The bottom reference used to be exempted along with the genuinely unresolved
hole, whose cast must stay accepted (it is polymorphic and unifies with whatever
its block needs). But "some reference, type not yet resolved" is not "unknown
whether a reference", so the check passed, `wax check` accepted the module, and
the lowering — which trusts its input — reached its cast-family catch-all and
died on an assertion instead of reporting anything (a wax-mutation-fuzzer crash,
mutant-270.wax, where the bottom reference arrived on a dead loop's stack).

  $ cat > f.wax <<'WAX'
  > fn f() {
  >     unreachable;
  >     _ = (_! as f32).to_bits();
  > }
  > WAX

  $ wax check f.wax
  Error: This value of type '&_' cannot be cast to the target type.
   ──➤  f.wax:3:10
  1 │ fn f() {
  2 │     unreachable;
  3 │     _ = (_! as f32).to_bits();
    ·          ^^
  4 │ }
  5 │ 
  [128]

Every numeric target is rejected the same way, and each one crashed the lowering
before:

  $ for t in f32 f64 i32 v128; do
  >   printf 'fn f() {\n    unreachable;\n    _ = _! as %s;\n}\n' "$t" > c.wax
  >   wax c.wax -f wat -o /dev/null 2>&1 | head -1
  > done
  Error: This value of type '&_' cannot be cast to the target type.
  Error: This value of type '&_' cannot be cast to the target type.
  Error: This value of type '&_' cannot be cast to the target type.
  Error: This value of type '&_' cannot be cast to the target type.

The reference targets and the SIGNED numeric casts are unaffected: a signedness
picks an `i31.get_s`/`_u`, which is a real lowering for a bottom reference (it
traps at runtime, like any other cast to `&i31`).

  $ cat > ok.wax <<'WAX'
  > fn f() {
  >     unreachable;
  >     _ = (_! as i32_s).ctz();
  >     _ = (_! as i64_u).ctz();
  >     _ = (_! as &i31);
  >     _ = (_! as &?any);
  > }
  > WAX

  $ wax ok.wax -f wat
  (func $f
    (unreachable)
    (drop (i32.ctz (i31.get_s (ref.cast (ref i31) (ref.as_non_null)))))
    (drop
      (i64.ctz
        (i64.extend_i32_u (i31.get_u (ref.cast (ref i31) (ref.as_non_null))))))
    (drop (ref.cast (ref i31) (ref.as_non_null)))
    (drop (ref.cast anyref (ref.as_non_null)))
  )
