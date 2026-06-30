`null!` (ref.as_non_null) on a bare, floating `null` is rejected: the null's
heap type is unknown, so there is no reference type to assert non-null on, and
the assertion would always trap anyway. (A `!` on a value whose reference type
is known — a local of reference type, a struct field, … — still works; only the
typeless bare null is refused.)

  $ cat > t.wax <<'EOF'
  > fn f() -> &none {
  >     null!;
  > }
  > EOF
  $ wax check -f wax t.wax
  Error:
    Cannot apply `!` to `null`: it has no reference type to assert non-null on (and the assertion would always trap).
   ──➤  t.wax:2:5
  1 │ fn f() -> &none {
  2 │     null!;
    ·     ^^^^
  3 │ }
  4 │ 
  Hint: Give the null a reference type, e.g. (null as &T)!.
  [123]
